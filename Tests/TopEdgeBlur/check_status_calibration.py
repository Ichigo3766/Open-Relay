"""Check exported *-calibration screenshots from the iPhone 16 Pro UI test.

Requires Pillow. The blank blue bubble isolates background lightening and blur
from text content. Native dark-mode contrast adjustment is permitted.
"""
import sys

from PIL import Image


def transition_width(image, y):
    width = image.width
    left = image.getpixel((round(width * 0.4), y))
    right = image.getpixel((round(width * 0.8), y))
    direction = [b - a for a, b in zip(left, right)]
    magnitude = sum(channel * channel for channel in direction)
    assert magnitude > 1000, "Expected the calibration bubble's vertical edge."
    positions = {}
    for x in range(round(width * 0.4), round(width * 0.8)):
        color = image.getpixel((x, y))
        progress = sum((c - a) * d for c, a, d in zip(color, left, direction)) / magnitude
        for threshold in (0.1, 0.9):
            if progress >= threshold:
                positions.setdefault(threshold, x)
    return positions[0.9] - positions[0.1]


def check(path):
    image = Image.open(path).convert("RGB")
    assert image.size == (1206, 2622), "Use the iPhone 16 Pro calibration capture."
    x = round(image.width * 0.85)
    top, body = image.getpixel((x, 30)), image.getpixel((x, 800))
    assert body[2] > body[0] + 80, "Expected the blank blue calibration bubble."
    lightening = max(0, *(a - b for a, b in zip(top, body)))
    # iPhone 16 Pro's top safe area is 62pt on this 3x simulator.
    upper_edge, lower_edge = transition_width(image, 60), transition_width(image, 186)
    print(f"Lightening: {lightening}/255; edge transition at 20pt: {upper_edge}px; at 62pt: {lower_edge}px")
    assert lightening <= 10, "The effect lightens the blank blue background."
    assert upper_edge >= 3, "Expected blur in the upper status area."
    assert lower_edge <= 4, "Blur extends below the status area."


if __name__ == "__main__":
    for path in sys.argv[1:]:
        check(path)
