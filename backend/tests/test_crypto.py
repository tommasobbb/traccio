"""Tests for the token encryption helper.

Pure unit tests: no database, no network. Fixtures use synthetic values only —
never a real bank token or a real key (see ``.claude/rules/data-safety.md``).
"""

import pytest
from cryptography.fernet import Fernet, InvalidToken

from traccio.core.crypto import TokenCipher, get_token_cipher

_KEY = Fernet.generate_key().decode()
_OTHER_KEY = Fernet.generate_key().decode()
_PLAINTEXT = "SYNTHETIC-CONSENT-TOKEN-01"


def test_encrypt_then_decrypt_round_trips() -> None:
    """Decrypting a ciphertext with the same key returns the original plaintext."""
    cipher = TokenCipher(_KEY)

    assert cipher.decrypt(cipher.encrypt(_PLAINTEXT)) == _PLAINTEXT


def test_ciphertext_is_not_the_plaintext() -> None:
    """The stored form does not contain the plaintext in the clear."""
    cipher = TokenCipher(_KEY)

    token = cipher.encrypt(_PLAINTEXT)

    assert _PLAINTEXT not in token


def test_decrypt_with_a_different_key_fails() -> None:
    """A token encrypted under one key cannot be decrypted with another."""
    token = TokenCipher(_KEY).encrypt(_PLAINTEXT)

    with pytest.raises(InvalidToken):
        TokenCipher(_OTHER_KEY).decrypt(token)


def test_tampered_ciphertext_fails() -> None:
    """Authenticated encryption rejects a modified token rather than returning garbage."""
    cipher = TokenCipher(_KEY)
    token = cipher.encrypt(_PLAINTEXT)

    tampered = token[:-2] + ("AA" if not token.endswith("AA") else "BB")

    with pytest.raises(InvalidToken):
        cipher.decrypt(tampered)


def test_malformed_key_raises_without_leaking_it() -> None:
    """A bad key raises a stable, value-free error (data-safety)."""
    bad_key = "not-a-valid-fernet-key"

    with pytest.raises(ValueError) as excinfo:
        TokenCipher(bad_key)

    assert bad_key not in str(excinfo.value)


def test_get_token_cipher_requires_a_configured_key() -> None:
    """The factory fails explicitly when the key is unset rather than later."""
    with pytest.raises(RuntimeError):
        get_token_cipher(None)


def test_get_token_cipher_builds_a_usable_cipher() -> None:
    """With a key set, the factory returns a working cipher."""
    cipher = get_token_cipher(_KEY)

    assert cipher.decrypt(cipher.encrypt(_PLAINTEXT)) == _PLAINTEXT
