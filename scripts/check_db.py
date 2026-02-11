# scripts/check_db.py
# Проверяет подключение к DATABASE_URL из app.core.config.settings
from sqlalchemy import create_engine, text
from app.core.config import settings

def main():
    url = settings.DATABASE_URL
    print('Trying to connect to:', url)
    connect_args = {"check_same_thread": False} if url.startswith("sqlite") else {}
    engine = create_engine(url, connect_args=connect_args)
    try:
        with engine.connect() as conn:
            print('Connection OK, SELECT 1 ->', conn.execute(text("SELECT 1")).scalar())
    except Exception as e:
        print('Connection failed:', e)

if __name__ == '__main__':
    main()
