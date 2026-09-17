"""Column-type helpers shared across the model submodules.

Split out so no submodule has to import another just to build a column.
"""

from enum import StrEnum

from sqlalchemy import Enum as SAEnum


def _enum_column(enum: type[StrEnum]) -> SAEnum:
    """Build a portable string-backed column type for a :class:`StrEnum`.

    Persists the enum's ``.value`` (not its member ``name``) as a plain
    ``VARCHAR``, rather than a native database enum type or a check constraint
    (``create_constraint`` is left at its SQLAlchemy default of ``False``).

    Parameters
    ----------
    enum : type[StrEnum]
        The domain enum to store.

    Returns
    -------
    Enum
        A SQLAlchemy ``Enum`` type persisting the string values.
    """
    return SAEnum(
        enum,
        native_enum=False,
        values_callable=lambda e: [member.value for member in e],
    )


# Fixed width for every "appearance token" column (colours, icons — see
# ``domain/enums.py``: PaletteColor, AccountIcon, and CategoryIcon once it
# lands). Unlike ``_enum_column``, which sizes the VARCHAR to the longest
# *current* member and has already needed two widening migrations when a
# later member turned out longer (``d1f4b6a29c73``, ``e2c4a8f1b6d3``), this is
# sized generously up front so adding a token never needs one. 32 comfortably
# fits every planned member with room to spare, and is still a real bound
# (unlike ``Text``, which would throw the type away for values that are in
# fact a closed, short vocabulary).
_TOKEN_COLUMN_LENGTH = 32


def _token_column(enum: type[StrEnum]) -> SAEnum:
    """Build a portable string-backed column type for an appearance token enum.

    Same shape as :func:`_enum_column` (plain ``VARCHAR``, no native enum
    type, no check constraint), but with a fixed :data:`_TOKEN_COLUMN_LENGTH`
    instead of a width derived from the enum's current members — see that
    constant's comment for why.

    Parameters
    ----------
    enum : type[StrEnum]
        The token enum to store.

    Returns
    -------
    Enum
        A SQLAlchemy ``Enum`` type persisting the string values in a
        fixed-width column.
    """
    return SAEnum(
        enum,
        native_enum=False,
        length=_TOKEN_COLUMN_LENGTH,
        values_callable=lambda e: [member.value for member in e],
    )
