"""The :class:`Money` value object.

Money in Traccio is always an integer number of the currency's minor unit
(cents), never a float, and always travels with an explicit ISO 4217 currency.
This module imports nothing from other project layers.
"""

from typing import Annotated

from pydantic import BaseModel, ConfigDict, StrictInt, StringConstraints

CurrencyCode = Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]


class Money(BaseModel):
    """An immutable amount in a single currency.

    The amount is expressed in integer minor units (e.g. cents): ``1234`` with
    currency ``"EUR"`` means €12.34. ``amount`` is a :class:`StrictInt`, so a
    float such as ``12.34`` is rejected rather than silently truncated —
    floating-point money is a class of bug this type exists to prevent.

    By the domain sign convention, a negative ``amount`` means money left the
    account and a positive one means it arrived; sign normalization per account
    kind is the provider adapter's responsibility, not this type's.

    Attributes
    ----------
    amount : int
        Value in the currency's minor unit (cents). May be negative.
    currency : str
        ISO 4217 code, three uppercase letters (e.g. ``"EUR"``). Never defaulted.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    amount: StrictInt
    currency: CurrencyCode
