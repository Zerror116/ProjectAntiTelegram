# app/core/config.py
# Конфигурация приложения с валидацией переменных окружения.
# Загружает .env (если установлен python-dotenv) и берёт переменные окружения.
# Экземпляр settings импортируется в других модулях.

import os
import warnings
from pathlib import Path

# Попытка загрузить .env (если установлен python-dotenv)
try:
    from dotenv import load_dotenv

    project_root = Path(__file__).resolve().parent.parent.parent
    env_path = project_root / ".env"
    if env_path.exists():
        load_dotenv(dotenv_path=env_path)
except Exception as e:
    # Если python-dotenv не установлен — продолжаем, переменные будут браться из окружения
    warnings.warn("python-dotenv not installed, using environment variables only")

BASE_DIR = Path(__file__).resolve().parent.parent


class Settings:
    """Основные настройки приложения с валидацией."""

    # URL базы данных: ожидается формат postgresql://user:pass@host:port/dbname
    DATABASE_URL: str = os.getenv(
        "DATABASE_URL",
        "postgresql://antitelegram_user:password@127.0.0.1:5432/antitelegram_db"
    )

    # Проверка: используются ли дефолтные учётные данные в продакшене
    def __post_init_checks__(self) -> None:
        """Проверяет конфигурацию на потенциальные проблемы."""
        env = os.getenv("ENVIRONMENT", "development").lower()

        # ⚠️ Проверка на дефолтные учётные данные в продакшене
        if env == "production" or env == "prod":
            if "password" in self.DATABASE_URL or "127.0.0.1" in self.DATABASE_URL:
                raise ValueError(
                    "❌ ОШИБКА: Используются дефолтные учётные данные БД в продакшене! "
                    "Установите правильные переменные окружения DATABASE_URL, SECRET_KEY и др."
                )
            if self.SECRET_KEY == "change_this_secret_in_prod":
                raise ValueError(
                    "❌ ОШИБКА: SECRET_KEY не изменён в продакшене! "
                    "Установите уникальное значение в переменной окружения SECRET_KEY"
                )

    # Секрет для JWT — обязательно замените в продакшене!
    SECRET_KEY: str = os.getenv("SECRET_KEY", "change_this_secret_in_prod")
    ALGORITHM: str = os.getenv("ALGORITHM", "HS256")
    ACCESS_TOKEN_EXPIRE_MINUTES: int = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", str(60 * 24 * 7)))

    # Путь для загрузки фай��ов (dev)
    UPLOAD_DIR: str = os.getenv("UPLOAD_DIR", str(BASE_DIR / "static_uploads"))

    # Окружение (development, staging, production)
    ENVIRONMENT: str = os.getenv("ENVIRONMENT", "development")

    # Прочие настройки
    DELIVERY_FREE_THRESHOLD: float = float(os.getenv("DELIVERY_FREE_THRESHOLD", "1500.0"))
    DELIVERY_FEE: float = float(os.getenv("DELIVERY_FEE", "350.0"))

    # Логирование
    LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO")

    def validate(self) -> None:
        """Выполняет всё время при создании settings."""
        try:
            self.__post_init_checks__()
        except ValueError as e:
            if self.ENVIRONMENT in ("production", "prod"):
                raise
            else:
                warnings.warn(str(e))


# Создаём глобальный экземпляр settings
settings = Settings()
# Выполняем валидацию
try:
    settings.validate()
except ValueError as e:
    print(f"⚠️ Config Warning: {e}")