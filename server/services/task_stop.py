"""Per-run checkpoints shared by async workers and their to_thread calls."""

import asyncio
import threading
from contextlib import contextmanager, suppress
from contextvars import ContextVar
from uuid import uuid4


class TaskStopped(BaseException):
    """Bypass per-item error fallbacks without 3.10 wait_for erasing a CancelledError subtype."""


_signal = ContextVar("task_stop_signal", default=None)
_active = {}
_lock = threading.Lock()


def run_id():
    return uuid4().hex


@contextmanager
def stop_scope(key):
    event = threading.Event()
    with _lock:
        _active[key] = event
    token = _signal.set(event)
    try:
        yield
    finally:
        _signal.reset(token)
        with _lock:
            _active.pop(key, None)


def signal_stop(key):
    with _lock:
        if event := _active.get(key):
            event.set()


def checkpoint():
    event = _signal.get()
    if event is not None and event.is_set():
        raise TaskStopped()


async def stoppable_request(operation):
    """Cancel network I/O, never interrupt a database or index commit."""
    if _signal.get() is None:
        return await operation
    work = asyncio.ensure_future(operation)
    try:
        while not work.done():
            checkpoint()
            await asyncio.wait({work}, timeout=0.25)
        checkpoint()
        return work.result()
    finally:
        if not work.done():
            work.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await work
