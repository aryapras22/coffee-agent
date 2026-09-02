#!/usr/bin/env python3
"""Derives Agentic/indonesian_beans.json from the Coffee Review corpus.

Reads Tools/coffee_corpus.json, keeps the single-origin Indonesian lots whose
growing region resolves to one island, and projects them onto the BeanProfile
schema. Beans the corpus cannot place stay out rather than being guessed at.

The source corpus lives under Tools/ rather than Agentic/ because everything in
Agentic/ is bundled into the app, and the app only needs the derived file.

Run from the repo root: python3 Tools/GenerateBeanProfiles.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Tools" / "coffee_corpus.json"
TARGET = ROOT / "Agentic" / "indonesian_beans.json"
SUPPLEMENT = ROOT / "Tools" / "bean_supplement.json"

# Ordered longest-first within each island so "bener meriah" wins over "aceh".
ISLANDS = {
    "sumatra": ["bener meriah", "lake toba", "simalungun", "sidikalang", "mandailing",
                "mandheling", "takengon", "bengkulu", "lampung", "lintong", "sumatra",
                "gayo", "aceh"],
    "java": ["pangalengan", "preanger", "malabar", "blawan", "jampit", "ijen", "java"],
    "sulawesi": ["enrekang", "sulawesi", "celebes", "kalossi", "mamasa", "toraja"],
    "bali": ["kintamani", "bali"],
    "flores": ["manggarai", "bajawa", "flores", "ngada"],
    "papua": ["new guinea", "baliem", "wamena", "papua"],
}

SUBREGIONS = [
    "Bener Meriah", "Lake Toba", "Simalungun", "Sidikalang", "Mandailing", "Mandheling",
    "Takengon", "Bengkulu", "Lampung", "Lintong", "Gayo", "Aceh", "Pangalengan",
    "Preanger", "Malabar", "Blawan", "Jampit", "Ijen", "Enrekang", "Kalossi", "Mamasa",
    "Toraja", "Kintamani", "Manggarai", "Bajawa", "Ngada", "Baliem", "Wamena",
]

PROCESS = {
    "washed": "washed",
    "natural": "natural",
    "honey": "honey",
    "wet-hulled": "wetHulled",
    "semi-washed": "semiWashed",
    "anaerobic": "other",
}

ROAST = {
    "Light": "light",
    "Medium-Light": "lightMedium",
    "Medium": "medium",
    "Medium-Dark": "mediumDark",
    "Dark": "dark",
    "Very Dark": "dark",
}

# Tags outside the schema's vocabulary are dropped, not coerced into a nearby
# note. A "roasty" lot is a fact about the roast, not about the bean's flavour.
FLAVORS = {
    "chocolate": "chocolate", "earthy": "earthy", "floral": "floral", "citrus": "citrus",
    "spice": "spice", "tobacco": "tobacco", "caramel": "caramel", "nutty": "nutty",
    "woody": "woody", "herbal": "herbal", "cedar": "cedar", "fruity": "fruity",
    "stone fruit": "fruity", "dried fruit": "fruity", "berry": "fruity",
    "tropical fruit": "fruity", "apple/pear": "fruity",
}

INTENSITY = {"low": "low", "medium": "medium", "high": "high"}


def island_of(text):
    found = {island for island, keys in ISLANDS.items() if any(k in text for k in keys)}
    return found.pop() if len(found) == 1 else None


def subregion_of(text, fallback):
    for name in SUBREGIONS:
        if name.lower() in text:
            return name
    return fallback


def profile(bean):
    text = f"{bean.get('origin_raw') or ''} {bean.get('name') or ''}".lower()
    island = island_of(text)
    if island is None:
        return None

    processes = [PROCESS[p] for p in bean.get("process", []) if p in PROCESS]
    flavors = []
    for tag in bean.get("flavor_tags", []):
        note = FLAVORS.get(tag)
        if note and note not in flavors:
            flavors.append(note)

    return {
        "id": bean["coffee_id"],
        "name": bean["name"],
        "island": island,
        "subregion": subregion_of(text, island.capitalize()),
        "altitudeMinMeters": None,
        "altitudeMaxMeters": None,
        "processingMethod": processes[0] if processes else "other",
        "variety": None,
        "flavorNotes": flavors,
        "acidity": INTENSITY.get(bean.get("acidity_level") or "", "medium"),
        "body": INTENSITY.get(bean.get("body_level") or "", "medium"),
        "roastRecommendation": ROAST.get(bean.get("roast_level") or "", "medium"),
        "cuppingScore": bean.get("rating"),
        "dataSource": "coffeeReview",
    }


def main():
    source = json.loads(SOURCE.read_text())
    derived = []
    for bean in source:
        if "Indonesia" not in bean.get("origin_countries", []):
            continue
        if bean.get("origin_is_blend") or not bean.get("rating"):
            continue
        built = profile(bean)
        if built and built["flavorNotes"]:
            derived.append(built)

    supplement = json.loads(SUPPLEMENT.read_text()) if SUPPLEMENT.exists() else []
    known = {b["id"] for b in derived}
    profiles = derived + [b for b in supplement if b["id"] not in known]
    profiles.sort(key=lambda b: (b["island"], b["name"]))

    TARGET.write_text(json.dumps(profiles, indent=1) + "\n")
    islands = {}
    for b in profiles:
        islands[b["island"]] = islands.get(b["island"], 0) + 1
    print(f"{len(profiles)} profiles ({len(derived)} derived, {len(profiles) - len(derived)} synthesis)")
    print(islands)


if __name__ == "__main__":
    main()
