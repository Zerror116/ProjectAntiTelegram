# app/core/config.py
# Простая конфигурация без зависимости от BaseSettings.
# Читает переменные окружения (и .env при наличии python-dotenv).
# Этот файл возвращает объект settings с нужными полями.

import os
from pathlib import Path

# Попробуйте загрузить .env (если установлен python-dotenv)
try:
    from dotenv import load_dotenv
    # ищем .env в корне проекта (один уровень выше app/)
    project_root = Path(__file__).resolve().parent.parent
    env_path = project_root / ".env"
    if env_path.exists():
        load_dotenv(dotenv_path=env_path)
except Exception:
    # если python-dotenv не установлен — просто продолжаем, переменные будут браться из окружения
    pass

BASE_DIR = Path(__file__).resolve().parent.parent

class Settings:
    """
    Класс настроек. Значения берутся из окружения с дефолтами.
    Используйте settings = Settings() в других модулях.
    """
    # URL базы данных: ожидается формат postgresql://user:pass@host:port/dbname
    DATABASE_URL: str = os.getenv(
        "DATABASE_URL",
        "postgresql://antitelegram_user:password@localhost:5432/antitelegram_db"
    )

    # Секрет для JWT — обязательно замените в продакшне
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change_this_secret_in_prod")
    ALGORITHM: str = os.getenv("ALGORITHM", "HS256")
    ACCESS_TOKEN_EXPIRE_MINUTES: int = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", 60 * 24 * 7))

    # Путь для загрузки изображений (dev)
    UPLOAD_DIR: str = os.getenv("UPLOAD_DIR", str(BASE_DIR / "static_uploads"))

    # Настройки доставки
    DELIVERY_FREE_THRESHOLD: float = float(os.getenv("DELIVERY_FREE_THRESHOLD", 1500.0))
    DELIVERY_FEE: float = float(os.getenv("DELIVERY_FEE", 350.0))

    # Дополнительные настройки можно добавлять здесь

# Экземпляр настроек, импортируйте settings в других модулях
settings = Settings()
