"""AI-Driven Database Workload Lab — Lambda service."""

from __future__ import annotations

import os

from ngx_workload_lab.logging_setup import configure_logging

# Configure structlog at package import time, BEFORE any submodule's
# module-level `logger = get_logger(...)` runs. With
# cache_logger_on_first_use=True the first usage locks in the active
# config; if configure_logging() runs after that, JSONRenderer never
# gets attached and CloudWatch metric filters that expect JSON-shaped
# events match nothing. Catching this in __init__ keeps every submodule
# logger on the same JSON renderer regardless of import order.
configure_logging(level=os.environ.get("LOG_LEVEL", "INFO"))

__version__ = "0.1.0"
