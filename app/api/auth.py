# app/api/auth.py
# Роуты для регистрации и получения JWT токена.
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from fastapi.security import OAuth2PasswordRequestForm
from datetime import timedelta

from app.core import security
from app.core.config import settings
from app.models.user import User, RoleEnum

router = APIRouter()

@router.post("/register")
def register(phone: str, password: str, full_name: str | None = None, db: Session = Depends(security.get_db)):
    """
    Регистрация пользователя: phone + password.
    По умолчанию роль = client.
    """
    existing = db.query(User).filter(User.phone == phone).first()
    if existing:
        raise HTTPException(status_code=400, detail="Phone already registered")
    hashed = security.get_password_hash(password)
    user = User(phone=phone, hashed_password=hashed, full_name=full_name, role=RoleEnum.client)
    db.add(user)
    db.commit()
    db.refresh(user)
    return {"id": user.id, "phone": user.phone, "role": user.role.value}

@router.post("/token")
def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(security.get_db)):
    """
    Логин: возвращает access_token (JWT).
    OAuth2PasswordRequestForm ожидает username и password — используем phone как username.
    """
    user = db.query(User).filter(User.phone == form_data.username).first()
    if not user or not user.hashed_password or not security.verify_password(form_data.password, user.hashed_password):
        raise HTTPException(status_code=400, detail="Incorrect credentials")
    access_token_expires = timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    token = security.create_access_token(subject=str(user.id), expires_delta=access_token_expires)
    return {"access_token": token, "token_type": "bearer"}
