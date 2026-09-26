"""Check the empty left gutter in the synthetic iPhone 16 Pro dark-color-0 capture.

Requires Pillow. This detects the lightening regression, not overall blur quality.
"""
import sys
from statistics import mean

from PIL import Image


def brightness(image, x, y):
    width, height = image.size
    left, top = round(width * x), round(height * y)
    return mean(mean(image.getpixel((left + dx, top + dy))) for dx in range(6) for dy in range(6))


def check(path):
    image = Image.open(path).convert("RGB")
    if image.size != (1206, 2622):
        raise ValueError("Use the iPhone 16 Pro dark-color-0 screenshot (1206 x 2622).")
    status = brightness(image, 0.03, 0.03)
    body = brightness(image, 0.03, 0.34)
    print(f"Status gutter: {status:.1f}/255; body gutter: {body:.1f}/255")
    assert body < 20, "Expected the synthetic dark background."
    assert status <= body + 8, "Status-area background is visibly lightened."


if __name__ == "__main__":
    check(sys.argv[1])
