#!/usr/bin/env python3
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "AppStoreAssets" / "Showcase" / "Sources-2026-07-25"
OUTPUT_DIR = ROOT / "AppStoreAssets" / "Showcase" / "en-US"

WIDTH = 1320
HEIGHT = 2868
RED = (229, 53, 53)
WHITE = (248, 248, 248)
MUTED = (142, 142, 146)
BACKGROUND = (8, 8, 9)
PANEL = (14, 14, 15)

DISPLAY_FONT = ROOT / "SpyClash" / "Resources" / "Rajdhani-Bold.ttf"
MONO_FONT = Path("/System/Library/Fonts/SFNSMono.ttf")


ITEMS = [
    {
        "filename": "01-find-the-spy.png",
        "source": "01-home.png",
        "headline": [("FIND THE", WHITE), ("SPY", RED)],
        "subtitle": "A SOCIAL DEDUCTION GAME FOR EVERY ROOM.",
        "label": "// MISSION START",
        "crop_y": 320,
    },
    {
        "filename": "02-question-bluff-survive.png",
        "source": "02-online-playing.png",
        "headline": [("QUESTION. BLUFF.", WHITE), ("SURVIVE.", RED)],
        "subtitle": "READ THE ROOM BEFORE THEY READ YOU.",
        "label": "// LIVE ROUND",
        "crop_y": 300,
    },
    {
        "filename": "03-your-role-your-secret.png",
        "source": "03-role-revealed.png",
        "headline": [("YOUR ROLE.", WHITE), ("YOUR SECRET.", RED)],
        "subtitle": "KEEP YOUR COVER. TRUST NO ONE.",
        "label": "// SECRET ROLE",
        "crop_y": 320,
    },
    {
        "filename": "04-build-your-missions.png",
        "source": "04-word-packs.png",
        "headline": [("BUILD YOUR", WHITE), ("OWN MISSIONS", RED)],
        "subtitle": "CREATE WORD PACKS FOR ANY CROWD.",
        "label": "// WORD PACKS",
        "crop_y": 330,
    },
    {
        "filename": "05-find-your-operatives.png",
        "source": "05-community.png",
        "headline": [("FIND YOUR", WHITE), ("OPERATIVES", RED)],
        "subtitle": "DISCOVER PLAYERS. BUILD YOUR NETWORK.",
        "label": "// COMMUNITY",
        "crop_y": 320,
    },
]


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size)


def cut_corner_polygon(box: tuple[int, int, int, int], cut: int) -> list[tuple[int, int]]:
    left, top, right, bottom = box
    return [
        (left + cut, top),
        (right - cut, top),
        (right, top + cut),
        (right, bottom - cut),
        (right - cut, bottom),
        (left + cut, bottom),
        (left, bottom - cut),
        (left, top + cut),
    ]


def draw_grid(draw: ImageDraw.ImageDraw) -> None:
    grid = (73, 16, 20)
    for x in range(72, WIDTH, 104):
        draw.line((x, 0, x, HEIGHT), fill=grid, width=1)
    for y in range(120, HEIGHT, 104):
        draw.line((0, y, WIDTH, y), fill=grid, width=1)


def draw_corner_marks(draw: ImageDraw.ImageDraw) -> None:
    x0, x1, y0, y1, length = 42, WIDTH - 42, 46, HEIGHT - 46, 54
    for x, sx in ((x0, 1), (x1, -1)):
        for y, sy in ((y0, 1), (y1, -1)):
            draw.line((x, y, x + sx * length, y), fill=RED, width=3)
            draw.line((x, y, x, y + sy * length), fill=RED, width=3)


def fit_display_font(text: str, max_width: int, initial_size: int) -> ImageFont.FreeTypeFont:
    size = initial_size
    while size > 72:
        candidate = font(DISPLAY_FONT, size)
        if candidate.getlength(text) <= max_width:
            return candidate
        size -= 2
    return font(DISPLAY_FONT, size)


def prepare_screen(path: Path, crop_y: int, size: tuple[int, int]) -> Image.Image:
    target_width, target_height = size
    with Image.open(path) as original:
        screen = original.convert("RGB")
    crop_y = min(max(crop_y, 0), max(0, screen.height - 1))
    crop_bottom = min(screen.height, crop_y + 1_980)
    crop = screen.crop((0, crop_y, screen.width, crop_bottom))
    return crop.resize((target_width, target_height), Image.Resampling.LANCZOS)


def make_card(item: dict) -> Image.Image:
    canvas = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    draw_grid(draw)
    draw_corner_marks(draw)

    brand_font = font(MONO_FONT, 31)
    draw.text((76, 112), "//", font=brand_font, fill=RED)
    draw.text((132, 112), "SPYCLASH", font=brand_font, fill=MUTED)
    draw.ellipse((1178, 122, 1194, 138), fill=RED)
    draw.text((1210, 112), "IOS", font=brand_font, fill=RED)

    headline_y = 212
    for text, color in item["headline"]:
        headline_font = fit_display_font(text, 1168, 164)
        draw.text((76, headline_y), text, font=headline_font, fill=color, stroke_width=1)
        line_box = draw.textbbox((76, headline_y), text, font=headline_font, stroke_width=1)
        headline_y = line_box[3] - 4

    subtitle_font = font(MONO_FONT, 29)
    draw.text((78, headline_y + 28), item["subtitle"], font=subtitle_font, fill=MUTED)

    panel_box = (76, 820, WIDTH - 76, HEIGHT - 76)
    panel_points = cut_corner_polygon(panel_box, 26)

    shadow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.polygon([(x + 6, y + 14) for x, y in panel_points], fill=(0, 0, 0, 185))
    shadow = shadow.filter(ImageFilter.GaussianBlur(24))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    draw = ImageDraw.Draw(canvas)
    draw.polygon(panel_points, fill=PANEL + (255,))

    inset = 15
    image_box = (panel_box[0] + inset, panel_box[1] + inset, panel_box[2] - inset, panel_box[3] - inset)
    image_size = (image_box[2] - image_box[0], image_box[3] - image_box[1])
    screen = prepare_screen(SOURCE_DIR / item["source"], item["crop_y"], image_size).convert("RGBA")
    mask = Image.new("L", image_size, 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.polygon(cut_corner_polygon((0, 0, image_size[0] - 1, image_size[1] - 1), 20), fill=255)
    screen.putalpha(mask)
    canvas.alpha_composite(screen, (image_box[0], image_box[1]))

    draw = ImageDraw.Draw(canvas)
    draw.line(panel_points + [panel_points[0]], fill=(77, 30, 32, 255), width=2, joint="curve")
    tab_box = (104, 785, 486, 865)
    draw.polygon(cut_corner_polygon(tab_box, 14), fill=(12, 12, 13, 255))
    draw.line((tab_box[0] + 18, tab_box[1], tab_box[0] + 82, tab_box[1]), fill=RED, width=4)
    draw.text((132, 808), item["label"], font=font(MONO_FONT, 25), fill=(198, 198, 200, 255))

    return canvas.convert("RGB")


def make_contact_sheet(outputs: list[Path]) -> None:
    thumb_width = 300
    thumb_height = round(HEIGHT * thumb_width / WIDTH)
    gap = 22
    sheet = Image.new("RGB", (gap + len(outputs) * (thumb_width + gap), thumb_height + gap * 2), (5, 5, 6))
    for index, path in enumerate(outputs):
        with Image.open(path) as image:
            thumb = image.convert("RGB").resize((thumb_width, thumb_height), Image.Resampling.LANCZOS)
        sheet.paste(thumb, (gap + index * (thumb_width + gap), gap))
    sheet.save(OUTPUT_DIR.parent / "preview-all-5.jpg", quality=92, optimize=True)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    outputs = []
    for item in ITEMS:
        output_path = OUTPUT_DIR / item["filename"]
        make_card(item).save(output_path, format="PNG", optimize=True)
        outputs.append(output_path)
    make_contact_sheet(outputs)


if __name__ == "__main__":
    main()
