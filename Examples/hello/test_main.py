import unittest

from main import Greeter


class GreeterTest(unittest.TestCase):
    def test_greet(self) -> None:
        self.assertEqual(Greeter().greet("Ada"), "Hello, Ada!")


if __name__ == "__main__":
    unittest.main()
