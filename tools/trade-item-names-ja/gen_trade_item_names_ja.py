"""トレードサイトのアイテム名・ベースタイプの英語→日本語対応表を生成する。

公式トレードサイトのアイテム一覧API（英語版www／日本語版jp）は同じ並びでエントリを返すため、
カテゴリごとに位置で対応付ける。ユニーク（nameを持つエントリ）は全カテゴリで件数と並びが一致する。
ベースタイプは日本語版で一部が欠けることがある（例: 2026-11時点で矢筒7件）ため、
件数が合わないカテゴリはユニークから得た対応を目印にして、目印間の件数が一致する区間だけ対応付ける。

使い方:
    python tools/trade-item-names-ja/gen_trade_item_names_ja.py
    python tools/trade-item-names-ja/gen_trade_item_names_ja.py --en items_www.json --ja items_jp.json

出力: src/Data/TradeItemNamesJa.lua
"""
import argparse
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUT = os.path.join(ROOT, "src", "Data", "TradeItemNamesJa.lua")
URLS = {
    "en": "https://www.pathofexile.com/api/trade2/data/items",
    "ja": "https://jp.pathofexile.com/api/trade2/data/items",
}


def load(lang, path):
    if path:
        with open(path, encoding="utf-8") as f:
            return json.load(f)["result"]
    req = urllib.request.Request(URLS[lang], headers={"User-Agent": "Path of Building"})
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.load(res)["result"]


def signature(entries):
    return [(e.get("flags"), e.get("disc")) for e in entries]


def add(mapping, key, value, conflicts):
    if key in mapping and mapping[key] != value:
        conflicts.append((key, mapping[key], value))
        return
    mapping[key] = value


def align_bases(en_bases, ja_bases, types, conflicts):
    """件数が一致しないベースタイプ一覧を、既知の対応を目印にして区間ごとに対応付ける。戻り値は対応付けられなかった英語エントリ数。"""
    ja_index = {e["type"]: j for j, e in enumerate(ja_bases)}
    anchors = []
    last_j = -1
    for i, e in enumerate(en_bases):
        j = ja_index.get(types.get(e["type"]))
        if j is not None and j > last_j:
            anchors.append((i, j))
            last_j = j
    anchors = [(-1, -1)] + anchors + [(len(en_bases), len(ja_bases))]
    skipped = 0
    for (i0, j0), (i1, j1) in zip(anchors, anchors[1:]):
        if i1 - i0 == j1 - j0:
            for k in range(1, i1 - i0):
                add(types, en_bases[i0 + k]["type"], ja_bases[j0 + k]["type"], conflicts)
        else:
            skipped += i1 - i0 - 1
            print("  対応付け不可:", ", ".join(en_bases[k]["type"] for k in range(i0 + 1, i1)))
    return skipped


def lua_string(s):
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ord(ch) < 0x20:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--en", help="英語版アイテム一覧JSON（省略時はAPIから取得）")
    parser.add_argument("--ja", help="日本語版アイテム一覧JSON（省略時はAPIから取得）")
    args = parser.parse_args()

    en = load("en", args.en)
    ja = load("ja", args.ja)
    if [c["id"] for c in en] != [c["id"] for c in ja]:
        sys.exit("カテゴリ構成が英語版と日本語版で一致しません")

    names, types, conflicts = {}, {}, []
    # 1. ユニーク: 件数と並びが一致するカテゴリだけ位置で対応付ける
    for ce, cj in zip(en, ja):
        ue = [e for e in ce["entries"] if "name" in e]
        uj = [e for e in cj["entries"] if "name" in e]
        if len(ue) != len(uj) or signature(ue) != signature(uj):
            print(f"警告: {ce['id']} のユニークが一致しないためスキップ ({len(ue)}/{len(uj)})")
            continue
        for a, b in zip(ue, uj):
            add(names, a["name"], b["name"], conflicts)
            add(types, a["type"], b["type"], conflicts)
    # 2. ベースタイプ: 件数が一致すれば位置で、一致しなければ目印を使って区間ごとに
    for ce, cj in zip(en, ja):
        be = [e for e in ce["entries"] if "name" not in e]
        bj = [e for e in cj["entries"] if "name" not in e]
        if len(be) == len(bj) and signature(be) == signature(bj):
            for a, b in zip(be, bj):
                add(types, a["type"], b["type"], conflicts)
        else:
            skipped = align_bases(be, bj, types, conflicts)
            print(f"{ce['id']}: ベースタイプ件数不一致 ({len(be)}/{len(bj)})、対応付けできなかった英語エントリ {skipped} 件")

    if conflicts:
        for c in conflicts[:20]:
            print("競合:", c)
        sys.exit(f"対応表に競合が {len(conflicts)} 件あります")
    # 日本語→英語の逆引きで一意にならないもの（公式訳が同じ）を報告する。実行時の逆引きからは除外される
    for label, mapping in (("name", names), ("type", types)):
        rev = {}
        for k, v in sorted(mapping.items()):
            rev.setdefault(v, []).append(k)
        for v, ks in rev.items():
            if len(ks) > 1:
                print(f"注意: {label} の日本語名が重複（逆引き不可）: {v} <- {', '.join(ks)}")

    lines = [
        "-- Path of Building",
        "--",
        "-- Data: TradeItemNamesJa",
        "-- フォーク専用: トレードサイトのアイテム名(name)・ベースタイプ(type)の英語→日本語対応表。",
        "-- 日本語版トレードサイトは英語名を解決できないため、URL生成時にこの表で日本語名へ置き換える。",
        "-- tools/trade-item-names-ja/gen_trade_item_names_ja.py で生成。手で編集しないこと。",
        "--",
        "return {",
    ]
    for label, mapping in (("name", names), ("type", types)):
        lines.append(f"\t{label} = {{")
        for k in sorted(mapping):
            lines.append(f"\t\t[{lua_string(k)}] = {lua_string(mapping[k])},")
        lines.append("\t},")
    lines.append("}")
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"name {len(names)} 件 / type {len(types)} 件を {os.path.relpath(OUTPUT, ROOT)} に出力")


if __name__ == "__main__":
    main()
