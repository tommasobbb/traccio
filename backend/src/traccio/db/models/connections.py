"""Persisted :class:`~traccio.domain.models.Connection`."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, String, Text, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column
from traccio.domain.enums import ConnectionStatus


class ConnectionRow(Base):
    """Persisted :class:`~traccio.domain.models.Connection`.

    Two columns hold secret/transient material that is deliberately **absent
    from the domain model** (which never carries tokens — see
    ``docs/architecture.md``): ``encrypted_credentials`` and ``auth_state``.
    They are written by :mod:`traccio.db.repositories`, not by the mappers.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    provider : str
        Adapter that produced the connection (e.g. ``"enable_banking"``).
    institution_name : str
        Human-readable bank name for display.
    institution_logo : str or None
        The bank's logo URL from the provider's institution list at
        connect time (Enable Banking ASPSP ``logo``). ``None`` for
        connections created before this column existed or when the provider
        had no logo. Cosmetic — the client falls back to a lettermark.
    country : str or None
        ISO 3166-1 alpha-2 country of the institution, as supplied when
        authorization started. ``None`` for connections created before this
        column existed.
    status : ConnectionStatus
        Consent lifecycle state, as last reported by the provider.
    expires_at : datetime or None
        Consent expiry; ``None`` while pending.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    encrypted_credentials : str or None
        The provider consent secret (Enable Banking ``session_id``) encrypted at
        rest with Fernet (see ``docs/decisions/0003-token-encryption-at-rest.md``).
        ``None`` while the connection is pending. Never logged, never returned by
        any endpoint.
    auth_state : str or None
        The anti-CSRF ``state`` issued when authorization started, used to match
        the SCA callback back to this pending connection. Unique; cleared to
        ``None`` once the connection is activated, re-set to a fresh value on
        re-authorization.
    last_synced_at : datetime or None
        When a sync last ran against this connection. ``None`` until the first
        sync; stamped by ``db/repositories.py::mark_connection_synced``.
    """

    __tablename__ = "connections"
    __table_args__ = (UniqueConstraint("auth_state"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    provider: Mapped[str] = mapped_column(String(64))
    institution_name: Mapped[str] = mapped_column(String(255))
    institution_logo: Mapped[str | None] = mapped_column(Text, nullable=True)
    country: Mapped[str | None] = mapped_column(String(2), nullable=True)
    status: Mapped[ConnectionStatus] = mapped_column(_enum_column(ConnectionStatus))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    encrypted_credentials: Mapped[str | None] = mapped_column(Text, nullable=True)
    auth_state: Mapped[str | None] = mapped_column(String(128), nullable=True)
    last_synced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
