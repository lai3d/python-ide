"""A tiny program for trying out PyIDE."""

from dataclasses import dataclass


@dataclass
class Greeter:
    punctuation: str = "!"

    def greet(self, name: str) -> str:
        """Return a friendly greeting."""
        return f"Hello, {name}{self.punctuation}"


def main() -> None:
    greeter = Greeter()
    for i, name in enumerate(["pythonista", "swift"]):
        print(i, greeter.greet(name))
    who = input("Your name? ")
    print(greeter.greet(who or "stranger"))


if __name__ == "__main__":
    main()
