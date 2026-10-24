#!/usr/bin/env python3
"""
SQL Server 2025 Vectors: Under the Hood and Into Production
Demo — RAG Application Web UI

Run:
    streamlit run demos/rag-app-ui.py

Architecture (same as rag-app.py, wrapped in a Streamlit chat interface):
    User question
        │
        ▼
    SQL Server 2025 — dbo.find_similar_questions
        ├── AI_GENERATE_EMBEDDINGS  (SQL Server → Ollama)
        ├── VECTOR_SEARCH (DiskANN), exact kNN while the index is rebuilt
        └── TOP K results
        │
        ▼
    SQL Server 2025 — dbo.get_top_answer (per result)
        │
        ▼
    RAG prompt assembly
        │
        ▼
    Ollama LLM (llama3.2) — direct HTTP from Python
        │
        ▼
    Streamlit chat UI
"""

import html
import html.parser
import os
import re
import time
from typing import Optional

import pyodbc
import requests
import streamlit as st


# ─── Configuration ────────────────────────────────────────────────────────────

SQL_SERVER   = os.environ.get("SQL_SERVER", "localhost,1435")
SQL_DATABASE = "StackOverflow"
SQL_USER     = "rag_app"
SQL_PASSWORD = "RagP@ss2025!"

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
LLM_MODEL       = "llama3.2"   # must be pulled: `ollama pull llama3.2`

TOP_K            = 5
MAX_ANSWER_CHARS = 800
REQUEST_TIMEOUT  = 300         # generous — llama3.2 on CPU can be slow


# ─── HTML helper ──────────────────────────────────────────────────────────────

class _HTMLStripper(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self._parts.append(data)

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in ("p", "br", "li", "pre", "div", "h1", "h2", "h3"):
            self._parts.append("\n")

    def get_text(self) -> str:
        return re.sub(r"\n{3,}", "\n\n", "".join(self._parts)).strip()


def strip_html(raw: str) -> str:
    stripper = _HTMLStripper()
    stripper.feed(raw)
    return stripper.get_text()


# ─── Database helpers ─────────────────────────────────────────────────────────

@st.cache_resource(show_spinner=False)
def get_connection() -> pyodbc.Connection:
    """Open and cache a single connection for the lifetime of the Streamlit app."""
    for driver in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server"):
        if driver in pyodbc.drivers():
            break
    else:
        st.error(
            "No ODBC driver found for SQL Server. "
            "Install 'ODBC Driver 18 for SQL Server'."
        )
        st.stop()

    conn_str = (
        f"DRIVER={{{driver}}};"
        f"SERVER={SQL_SERVER};"
        f"DATABASE={SQL_DATABASE};"
        f"UID={SQL_USER};"
        f"PWD={SQL_PASSWORD};"
        f"TrustServerCertificate=yes;"
        f"Encrypt=yes;"
    )
    return pyodbc.connect(conn_str, autocommit=True)


def find_similar_questions(prompt: str, top: int = TOP_K) -> list[dict]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute(
        "EXEC dbo.find_similar_questions @prompt = ?, @top = ?",
        prompt,
        top,
    )
    columns = [col[0] for col in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def get_top_answer(question_post_id: int) -> Optional[dict]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute(
        "EXEC dbo.get_top_answer @question_post_id = ?",
        question_post_id,
    )
    row = cursor.fetchone()
    if row is None:
        return None
    columns = [col[0] for col in cursor.description]
    return dict(zip(columns, row))


# ─── LLM helper (streaming) ───────────────────────────────────────────────────

def stream_ollama(prompt: str, model: str = LLM_MODEL):
    """
    Generator that yields text chunks from Ollama's streaming /api/generate.
    Streaming updates the Streamlit UI token-by-token instead of one long wait.
    """
    try:
        with requests.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json={"model": model, "prompt": prompt, "stream": True},
            stream=True,
            timeout=REQUEST_TIMEOUT,
        ) as resp:
            resp.raise_for_status()
            for line in resp.iter_lines():
                if not line:
                    continue
                import json
                chunk = json.loads(line)
                if token := chunk.get("response"):
                    yield token
                if chunk.get("done"):
                    break
    except requests.exceptions.ConnectionError:
        raise RuntimeError(
            f"Cannot reach Ollama at {OLLAMA_BASE_URL}. "
            "Is Ollama running on the host?"
        )
    except requests.exceptions.HTTPError as exc:
        if exc.response.status_code == 404:
            raise RuntimeError(
                f"Model '{model}' not found in Ollama. "
                f"Pull it first:  ollama pull {model}"
            )
        raise


# ─── RAG prompt ───────────────────────────────────────────────────────────────

def build_rag_prompt(user_question: str, results: list[dict]) -> str:
    context_blocks: list[str] = []

    for i, r in enumerate(results, start=1):
        lines = [
            f"--- Context {i} (similarity distance: {r.get('distance', '?'):.3f}) ---",
            f"Question: {r['title']}",
            f"Tags: {r.get('tags', '(none)')}",
            f"Community votes: {r.get('community_score', 0)}",
        ]
        answer_body = r.get("answer_body")
        if answer_body:
            plain = strip_html(answer_body)
            if len(plain) > MAX_ANSWER_CHARS:
                plain = plain[:MAX_ANSWER_CHARS] + "…"
            lines.append(f"Top answer excerpt:\n{plain}")
        else:
            lines.append("(no answer retrieved)")
        context_blocks.append("\n".join(lines))

    context = "\n\n".join(context_blocks)

    return f"""\
You are a helpful technical assistant grounding your answers in StackOverflow content.

Answer the user's question using ONLY the context provided below. If the context does
not contain enough information to answer confidently, say so clearly rather than
guessing.  Cite the most relevant question title when appropriate.

USER QUESTION:
{user_question}

RETRIEVED STACKOVERFLOW CONTEXT:
{context}

ANSWER:"""


# ─── Streamlit UI ─────────────────────────────────────────────────────────────

st.set_page_config(
    page_title="SQL Server 2025 Vector Search",
    page_icon="🔍",
    layout="wide",
)

st.title("SQL Server 2025 · Vector RAG Demo")
st.caption(
    "Ask any programming question — SQL Server handles the vector search, "
    "Ollama generates the answer."
)

# Sidebar: configuration and stack status
with st.sidebar:
    st.header("Stack")
    st.markdown(f"""
| Component | Details |
|-----------|---------|
| **SQL Server** | `{SQL_SERVER}` |
| **Database** | `{SQL_DATABASE}` |
| **LLM model** | `{LLM_MODEL}` |
| **Top K** | `{TOP_K}` results |
""")

    st.divider()
    st.header("How it works")
    st.markdown("""
1. Your question → **SQL Server**
2. SQL Server calls **Ollama** to embed the text
3. `VECTOR_SEARCH` walks the DiskANN graph (exact kNN if the index is dropped)
4. Top answers fetched from `dbo.Posts`
5. RAG prompt assembled and sent to **llama3.2**
6. Answer streamed back here
""")
    st.divider()
    if st.button("Clear chat history"):
        st.session_state.messages = []
        st.rerun()

# Initialise chat history
if "messages" not in st.session_state:
    st.session_state.messages = []

# Render existing chat history
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])
        if msg.get("context"):
            with st.expander(f"Retrieved context ({len(msg['context'])} results)", expanded=False):
                for r in msg["context"]:
                    dist = r.get("distance", 0)
                    color = "green" if dist < 0.2 else "orange" if dist < 0.35 else "red"
                    st.markdown(
                        f"**:{color}[{dist:.3f}]** &nbsp; {r['title']}  \n"
                        f"Tags: `{r.get('tags','—')}` · Score: {r.get('community_score',0)}"
                    )

# Chat input at the bottom
if question := st.chat_input("Ask a programming question…"):

    # Show user message immediately
    st.session_state.messages.append({"role": "user", "content": question})
    with st.chat_message("user"):
        st.markdown(question)

    with st.chat_message("assistant"):

        # ── Step 1: vector search in SQL Server ──────────────────────────────
        with st.status("Searching SQL Server…", expanded=False) as status:
            t0 = time.perf_counter()
            try:
                similar = find_similar_questions(question, top=TOP_K)
            except Exception as exc:
                st.error(f"SQL Server error: {exc}")
                st.stop()

            retrieval_ms = (time.perf_counter() - t0) * 1000

            # ── Step 2: fetch answers ─────────────────────────────────────────
            for q in similar:
                answer = get_top_answer(q["post_id"])
                q["answer_body"] = answer["answer_body"] if answer else None

            total_db_ms = (time.perf_counter() - t0) * 1000
            status.update(
                label=f"Retrieved {len(similar)} results in {total_db_ms:.0f} ms "
                      f"({similar[0].get('search_path', '?') if similar else '-'})",
                state="complete",
            )

        # Show retrieved context in an expander while the LLM generates
        with st.expander(f"Retrieved context ({len(similar)} results)", expanded=False):
            for r in similar:
                dist = r.get("distance", 0)
                color = "green" if dist < 0.2 else "orange" if dist < 0.35 else "red"
                st.markdown(
                    f"**:{color}[{dist:.3f}]** &nbsp; {r['title']}  \n"
                    f"Tags: `{r.get('tags','—')}` · Score: {r.get('community_score',0)}"
                )

        # ── Step 3: stream the LLM answer ────────────────────────────────────
        prompt = build_rag_prompt(question, similar)
        t1 = time.perf_counter()
        try:
            answer_text = st.write_stream(stream_ollama(prompt))
        except RuntimeError as exc:
            st.error(str(exc))
            st.stop()

        gen_ms = (time.perf_counter() - t1) * 1000
        st.caption(
            f"Retrieval: {total_db_ms:.0f} ms · "
            f"Generation: {gen_ms / 1000:.1f} s · "
            f"Model: {LLM_MODEL}"
        )

    # Persist the assistant message (with context for re-renders)
    st.session_state.messages.append({
        "role": "assistant",
        "content": answer_text,
        "context": similar,
    })
