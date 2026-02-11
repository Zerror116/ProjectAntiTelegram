# app/core/config.py
# Простая конфигурация без зависимости от pydantic BaseSettings.
# Загружает .env (если установлен python-dotenv) и берёт переменные окружения.
# Экземпляр settings импортируется в других модулях.

import os
from pathlib import Path

# Попытка загрузить .env (если установлен python-dotenv)
try:
    from dotenv import load_dotenv
    project_root = Path(__file__).resolve().parent.parent
    env_path = project_root / ".env"
    if env_path.exists():
        load_dotenv(dotenv_path=env_path)
except Exception:
    # Если python-dotenv не установлен — продолжаем, переменные будут браться из окружения
    pass

BASE_DIR = Path(__file__).resolve().parent.parent

class Settings:
    # URL базы данных: ожидается формат postgresql://user:pass@host:port/dbname
    DATABASE_URL: str = os.getenv(
        "DATABASE_URL",
        "postgresql://antitelegram_user:password@127.0.0.1:5432/antitelegram_db"
    )

    # Секрет для JWT — замените в продакшне
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change_this_secret_in_prod")
    ALGORITHM: str = os.getenv("ALGORITHM", "HS256")
    ACCESS_TOKEN_EXPIRE_MINUTES: int = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", 60 * 24 * 7))

    # Путь для загрузки файлов (dev)
    UPLOAD_DIR: str = os.getenv("UPLOAD_DIR", str(BASE_DIR / "static_uploads"))

    # Прочие настройки
    DELIVERY_FREE_THRESHOLD: float = float(os.getenv("DELIVERY_FREE_THRESHOLD", 1500.0))
    DELIVERY_FEE: float = float(os.getenv("DELIVERY_FEE", 350.0))

settings = Settings()
