#!/usr/bin/env python3
"""
SQL Server 2025 Vectors: Under the Hood and Into Production
Demo 4 — Python RAG Application

Retrieval-Augmented Generation over the StackOverflow dataset.

Architecture
────────────
User question
    │
    ▼
SQL Server 2025 — dbo.find_similar_questions
    ├── AI_GENERATE_EMBEDDINGS   ← SQL Server calls Ollama to embed the query
    ├── VECTOR_SEARCH (DiskANN)  ← ANN graph walk; exact kNN if the index is dropped
    └── TOP (K) results          ← returns the closest K questions + chunk text
    │
    ▼
SQL Server 2025 — dbo.get_top_answer (per result)
    └── accepted or highest-scored answer body
    │
    ▼
RAG prompt assembly
    └── "Answer this question using the following StackOverflow context..."
    │
    ▼
Ollama LLM (llama3.2, mistral, etc.) — direct HTTP call from Python
    └── grounded answer
    │
    ▼
Output to the terminal

Key design choices
──────────────────
- SQL Server handles ALL embedding and retrieval. The app sends plain text.
- The Python app never writes a VECTOR_DISTANCE or VECTOR_SEARCH call.
- The LLM is called directly from Python (not through SQL Server) because
  generation requires a chat-capable model, not just an embedding model.
- Connections use the least-privilege rag_app login from Demo 3.

Requirements
────────────
    pip install pyodbc requests
    (or: pip install -r requirements.txt)

    SQL Server: localhost,1435  (the docker-compose stack from this repo)
    Ollama:     http://localhost:11434  (running on the host)

    The LLM_MODEL must be pulled in Ollama before running:
        ollama pull llama3.2       # recommended
        ollama pull mistral        # lighter-weight alternative

Usage
─────
    # Interactive mode:
    python rag-app.py

    # Single question:
    python rag-app.py "how do I undo my last git commit?"
"""

import html
import html.parser
import os
import re
import sys
import textwrap
import time
from typing import Optional

import pyodbc
import requests


# ─── Configuration ────────────────────────────────────────────────────────────

SQL_SERVER   = os.environ.get("SQL_SERVER", "localhost,1435")
SQL_DATABASE = "StackOverflow"
SQL_USER     = "rag_app"
SQL_PASSWORD = "RagP@ss2025!"

OLLAMA_BASE_URL  = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
LLM_MODEL        = "llama3.2"   # must be pulled: `ollama pull llama3.2`

TOP_K            = 5            # number of similar questions to retrieve
MAX_ANSWER_CHARS = 800          # characters of answer body to include in context
REQUEST_TIMEOUT  = 300          # seconds to wait for the LLM response (first load is slow)


# ─── HTML helper ──────────────────────────────────────────────────────────────

class _HTMLStripper(html.parser.HTMLParser):
    """Minimal HTML-to-plain-text converter using only the standard library."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self._parts.append(data)

    def handle_starttag(self, tag: str, attrs) -> None:
        # Insert a newline before block-level elements so code blocks and
        # paragraphs are still readable in plain text.
        if tag in ("p", "br", "li", "pre", "div", "h1", "h2", "h3"):
            self._parts.append("\n")

    def get_text(self) -> str:
        return re.sub(r"\n{3,}", "\n\n", "".join(self._parts)).strip()


def strip_html(raw: str) -> str:
    """Strip HTML tags and unescape entities, returning readable plain text."""
    stripper = _HTMLStripper()
    stripper.feed(raw)
    return stripper.get_text()


# ─── Database helpers ─────────────────────────────────────────────────────────

def _get_driver() -> str:
    """Return the best available ODBC driver name for SQL Server."""
    for driver in ("ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server"):
        if driver in pyodbc.drivers():
            return driver
    raise RuntimeError(
        "No ODBC driver found for SQL Server. "
        "Install 'ODBC Driver 18 for SQL Server' from "
        "https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server"
    )


def get_connection() -> pyodbc.Connection:
    """Open a connection to SQL Server using the least-privilege rag_app login."""
    driver = _get_driver()
    conn_str = (
        f"DRIVER={{{driver}}};"
        f"SERVER={SQL_SERVER};"
        f"DATABASE={SQL_DATABASE};"
        f"UID={SQL_USER};"
        f"PWD={SQL_PASSWORD};"
        f"TrustServerCertificate=yes;"   # self-signed cert in the demo stack
        f"Encrypt=yes;"
    )
    return pyodbc.connect(conn_str, autocommit=True)


def find_similar_questions(
    conn: pyodbc.Connection,
    prompt: str,
    top: int = TOP_K,
) -> list[dict]:
    """
    Call dbo.find_similar_questions.

    SQL Server handles:
      - Embedding @prompt via AI_GENERATE_EMBEDDINGS (calls host Ollama)
      - VECTOR_SEARCH over the DiskANN index (exact kNN while it's rebuilt)
      - Returning the top-K most semantically similar questions

    The application sends plain text.  The embedding and vector search are
    entirely database operations.  The returned rows contain no VECTOR data.
    """
    cursor = conn.cursor()
    cursor.execute(
        "EXEC dbo.find_similar_questions @prompt = ?, @top = ?",
        prompt,
        top,
    )
    columns = [col[0] for col in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def get_top_answer(
    conn: pyodbc.Connection,
    question_post_id: int,
) -> Optional[dict]:
    """
    Call dbo.get_top_answer to retrieve the accepted (or highest-scored) answer
    for a given StackOverflow question post ID.

    Returns None when no answer rows exist for that question.
    """
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


# ─── LLM helper ───────────────────────────────────────────────────────────────

def call_ollama(prompt: str, model: str = LLM_MODEL) -> str:
    """
    Call the Ollama LLM for text generation using /api/generate (non-streaming).

    The LLM call is made from Python, not from SQL Server.  SQL Server's
    AI_GENERATE_EMBEDDINGS uses an EMBEDDINGS model (nomic-embed-text).
    Generating a grounded answer requires a chat/instruct model (llama3.2, etc.).
    These are two different models with different roles:

      nomic-embed-text   →  SQL Server  →  converts text to VECTOR(768)
      llama3.2           →  Python      →  generates a natural-language answer
    """
    try:
        response = requests.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json={"model": model, "prompt": prompt, "stream": False},
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
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

    return response.json()["response"]


# ─── RAG pipeline ─────────────────────────────────────────────────────────────

def build_rag_prompt(user_question: str, results: list[dict]) -> str:
    """
    Assemble the RAG prompt from:
      - The user's question
      - Retrieved StackOverflow questions (titles, tags, scores)
      - Their top answers (truncated, HTML-stripped)

    The prompt instructs the LLM to answer using only the provided context
    and to say so if the context is insufficient.
    """
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
            plain_answer = strip_html(answer_body)
            if len(plain_answer) > MAX_ANSWER_CHARS:
                plain_answer = plain_answer[:MAX_ANSWER_CHARS] + "…"
            lines.append(f"Top answer excerpt:\n{plain_answer}")
        else:
            lines.append("(no answer retrieved for this question)")

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


def answer_question(user_question: str) -> None:
    """
    Full RAG pipeline for one question:

      1. Retrieve top-K semantically similar questions via SQL Server
      2. Fetch the best answer for each retrieved question
      3. Assemble the RAG prompt (question + context)
      4. Call the Ollama LLM
      5. Print the grounded answer
    """
    print(f"\nQuestion: {user_question}")
    print("─" * 72)

    # ── Step 1: vector search in SQL Server ──────────────────────────────────
    t0 = time.perf_counter()
    print(f"\n[1/4] Searching SQL Server for top {TOP_K} similar questions…")

    with get_connection() as conn:
        similar = find_similar_questions(conn, user_question, top=TOP_K)

        if not similar:
            print("  No similar questions found in the embeddings table.")
            return

        retrieval_ms = (time.perf_counter() - t0) * 1000
        path = similar[0].get("search_path", "?")
        print(f"      Retrieved {len(similar)} results in {retrieval_ms:.0f} ms ({path})")
        print()
        for q in similar:
            print(f"  [{q['distance']:.3f}]  {q['title']}")

        # ── Step 2: fetch answers ─────────────────────────────────────────────
        print(f"\n[2/4] Fetching top answers for context…")
        for q in similar:
            answer = get_top_answer(conn, q["post_id"])
            q["answer_body"] = answer["answer_body"] if answer else None

    # ── Step 3: assemble prompt ───────────────────────────────────────────────
    print(f"\n[3/4] Assembling RAG prompt…")
    prompt = build_rag_prompt(user_question, similar)

    # ── Step 4: LLM generation ────────────────────────────────────────────────
    t1 = time.perf_counter()
    print(f"\n[4/4] Generating answer with {LLM_MODEL}…")
    answer_text = call_ollama(prompt)
    generation_ms = (time.perf_counter() - t1) * 1000
    print(f"      Generated in {generation_ms:.0f} ms")

    # ── Step 5: display ───────────────────────────────────────────────────────
    print()
    print("═" * 72)
    print("ANSWER")
    print("═" * 72)
    # Wrap long lines for terminal readability:
    for paragraph in answer_text.split("\n"):
        if paragraph.strip():
            print(textwrap.fill(paragraph, width=72))
        else:
            print()
    print()


# ─── Entry point ──────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) > 1:
        # Single question from command line:
        question = " ".join(sys.argv[1:])
        answer_question(question)
    else:
        # Interactive REPL:
        print("SQL Server 2025 RAG App — StackOverflow Q&A")
        print(f"  Embedding + retrieval: SQL Server at {SQL_SERVER}")
        print(f"  Answer generation:     Ollama ({LLM_MODEL}) at {OLLAMA_BASE_URL}")
        print("Type a question and press Enter.  Ctrl+C to exit.\n")

        while True:
            try:
                question = input("Question> ").strip()
                if not question:
                    continue
                answer_question(question)
            except KeyboardInterrupt:
                print("\nBye.")
                break
            except RuntimeError as exc:
                print(f"\nError: {exc}\n")
            except pyodbc.Error as exc:
                print(f"\nDatabase error: {exc}\n")


if __name__ == "__main__":
    main()
