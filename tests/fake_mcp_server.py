"""A small stdio MCP server for the connector tests: one read-only tool, one that writes, one that fails."""
import os
import sys

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

server = FastMCP('Notes')
NOTES = ['probe results on layer 12', 'eval batch notes']


@server.tool(annotations=ToolAnnotations(readOnlyHint=True))
def search_notes(query: str) -> str:
    """Find notes that mention the query."""
    return '\n'.join(n for n in NOTES if query.lower() in n) or 'nothing found'


@server.tool()
def add_note(text: str) -> str:
    """Save a note."""
    NOTES.append(text)
    return f'saved ({len(NOTES)} notes)'


@server.tool(annotations=ToolAnnotations(readOnlyHint=True))
def whoami() -> str:
    """Says the token the connector was started with."""
    return os.environ.get('NOTES_TOKEN', 'no token')


@server.tool()
def broken() -> str:
    """Always fails."""
    raise RuntimeError('the notes database is locked')


if __name__ == '__main__':
    print('notes server starting', file=sys.stderr)
    server.run()
