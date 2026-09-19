"""Symmetric encryption for secrets stored at rest (bank tokens/consents).

The scheme is Fernet (AES-128-CBC + HMAC-SHA256) from the ``cryptography``
library; the rationale and alternatives are in
``docs/decisions/0003-token-encryption-at-rest.md``. A single key, held **outside
the database** in the ``TRACCIO_ENCRYPTION_KEY`` environment variable, encrypts
and decrypts the provider credentials persisted against a ``Connection``.

Like :mod:`traccio.core.logging`, this module takes the key as a plain argument
rather than importing :mod:`traccio.core.config`, so ``core/`` stays free of
internal coupling; the caller reads the key from settings and passes it in.

Data safety (``docs/engineering.md``): this module never logs, and no
exception it raises contains the key or any plaintext — a leak here is an
incident, not a bug.
"""

from cryptography.fernet import Fernet


class TokenCipher:
    """Encrypts and decrypts short secrets with a single Fernet key.

    Fernet output is authenticated: a wrong key or a tampered ciphertext fails
    to decrypt (raising :class:`cryptography.fernet.InvalidToken`) rather than
    returning garbage.

    Parameters
    ----------
    key : str
        A url-safe base64-encoded 32-byte Fernet key (see
        :func:`cryptography.fernet.Fernet.generate_key`). A malformed key raises
        :class:`ValueError` with a stable, value-free message.
    """

    def __init__(self, key: str) -> None:
        try:
            self._fernet = Fernet(key.encode())
        except (ValueError, TypeError) as exc:
            # The underlying message ("Fernet key must be 32 url-safe
            # base64-encoded bytes.") does not contain the key value, so it is
            # safe to chain; never interpolate the key into the message.
            raise ValueError("invalid encryption key") from exc

    def encrypt(self, plaintext: str) -> str:
        """Return ``plaintext`` encrypted into a url-safe token string."""
        return self._fernet.encrypt(plaintext.encode()).decode()

    def decrypt(self, token: str) -> str:
        """Return the plaintext for ``token``.

        Raises
        ------
        cryptography.fernet.InvalidToken
            If the token was produced with a different key or has been tampered
            with.
        """
        return self._fernet.decrypt(token.encode()).decode()


def get_token_cipher(key: str | None) -> TokenCipher:
    """Build a :class:`TokenCipher`, requiring the key to be configured.

    A thin factory for callers that read the key from settings
    (``get_settings().encryption_key``). Kept separate so the "key is unset"
    failure is explicit at the point of use rather than surfacing as a confusing
    error deeper down.

    Parameters
    ----------
    key : str or None
        The configured key, or ``None`` when ``TRACCIO_ENCRYPTION_KEY`` is unset.

    Returns
    -------
    TokenCipher
        A cipher ready to encrypt/decrypt.

    Raises
    ------
    RuntimeError
        If ``key`` is ``None`` — encrypting or decrypting a stored secret is not
        possible without a configured key.
    """
    if key is None:
        raise RuntimeError(
            "TRACCIO_ENCRYPTION_KEY is not set; a key is required to handle stored credentials"
        )
    return TokenCipher(key)
