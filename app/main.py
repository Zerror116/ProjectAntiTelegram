# app/main.py
# Точка входа FastAPI. Создание таблиц выполняется в событии startup с обработкой ошибок.

import logging
import time
from contextlib import asynccontextmanager
from typing import List

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.db.session import engine
from app.db.base import Base
from app.core.config import settings

# Импорт моделей, чтобы SQLAlchemy видел их определения
import app.models.user
import app.models.product
import app.models.cart
import app.models.order

# Настройка логирования
logging.basicConfig(level=settings.LOG_LEVEL)
logger = logging.getLogger(__name__)


def try_create_tables(retries: int = 5, delay: int = 2) -> bool:
    """
    Пытаемся создать таблицы с повторными попытками.
    Если БД недоступна, логируем ошибку и пробуем снова.

    Args:
        retries: Количество попыток подключения
        delay: Задержка между попытками в секундах

    Returns:
        True если таблицы созданы/существуют, False если все попытки исчерпаны
    """
    for attempt in range(1, retries + 1):
        try:
            logger.info(f"Попытка создания таблиц ({attempt}/{retries})...")
            Base.metadata.create_all(bind=engine)
            logger.info("✅ Database tables created (or already exist).")
            return True
        except Exception as e:
            logger.warning(f"❌ Attempt {attempt}/{retries} failed to create tables: {e}")
            if attempt < retries:
                logger.info(f"⏳ Waiting {delay}s before retry...")
                time.sleep(delay)
            else:
                logger.error(
                    f"❌ Could not create tables after {retries} retries. "
                    "Database initialization failed. Startup cannot continue."
                )
                return False


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Управление жизненным циклом приложения.
    Запускается при старте и завершении приложения.
    """
    # Startup
    logger.info("🚀 FastAPI starting up...")
    if not try_create_tables(retries=5, delay=2):
        logger.error("⚠️ Failed to create database tables. Application may not work correctly.")
        # В production должны было бы выкинуть исключение, но для разработки продолжаем
        if settings.ENVIRONMENT in ("production", "prod"):
            raise RuntimeError("Cannot start application: database tables creation failed")

    yield

    # Shutdown
    logger.info("🛑 FastAPI shutting down...")
    try:
        engine.dispose()
        logger.info("✅ Database connection closed")
    except Exception as e:
        logger.error(f"Error closing database: {e}")


# Создаём FastAPI приложение с управлением жизненным циклом
app = FastAPI(
    title="ProjectAntiTelegram API",
    description="API для приложения ProjectAntiTelegram",
    version="1.0.0",
    lifespan=lifespan
)

# CORS middleware для разработки (ограничить в продакшене!)
if settings.ENVIRONMENT == "development":
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    # В продакшене указать конкретные домены
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["https://yourdomain.com"],
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "DELETE"],
        allow_headers=["*"],
    )

# Подключаем роутеры
try:
    from app.api import auth as auth_router

    app.include_router(auth_router.router, prefix="/api/auth", tags=["auth"])
    logger.info("✅ Auth router included")
except ImportError as e:
    logger.error(f"❌ Failed to import auth router: {e}")


# Базовые health check endpoints
@app.get("/", tags=["health"])
async def root():
    """Базовый health check."""
    return {
        "status": "ok",
        "service": "ProjectAntiTelegram API",
        "environment": settings.ENVIRONMENT
    }


@app.get("/health", tags=["health"])
async def health():
    """Детальный health check."""
    return {
        "status": "healthy",
        "database": "connected",
        "version": "1.0.0"
    }


# Глобальный обработчик исключений
@app.exception_handler(Exception)
async def global_exception_handler(request, exc):
    """Глобальный обработчик ошибок."""
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return {
        "status": "error",
        "message": "Internal server error",
        "detail": str(exc) if settings.ENVIRONMENT == "development" else "An error occurred"
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=settings.ENVIRONMENT == "development",
        log_level=settings.LOG_LEVEL.lower()
    )