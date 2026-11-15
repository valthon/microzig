#!/usr/bin/env python3
"""Generate the committed differential oracle using the supplied pioasm binary."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def keyword_spellings(lexer_path):
    """Use the reference lexer's literal keyword rules, not a second word list."""
    rules = Path(lexer_path).read_text()
    if not re.search(r'^%option[^\n]*\bcase-insensitive\b', rules, re.M):
        raise ValueError('reference lexer no longer declares case-insensitive rules')
    literals = re.findall(r'^\s*"([^"\n]+)"[^\n]*\breturn yy::parser::make_', rules, re.M)
    return {word.lower() for word in literals if re.fullmatch(r'\.?[A-Za-z_][A-Za-z_0-9]*', word)}


def case_variant(source, keywords, style):
    """Change INITIAL-state keyword tokens; keep IDs and other states verbatim."""
    pieces = []
    position = 0
    changed_keyword = False
    while position < len(source):
        rest = source[position:]
        end = None
        if rest.startswith('/*'):
            close = source.find('*/', position + 2)
            end = len(source) if close < 0 else close + 2
        elif rest.startswith('//') or rest.startswith(';'):
            close = source.find('\n', position)
            end = len(source) if close < 0 else close + 1
        elif rest.startswith('%'):
            # CODE_BLOCK_START and CODE_BLOCK_CONTENTS contain format names
            # and foreign-language text, not INITIAL-state keywords.
            block_start = re.match(r'%[ \t\r]*[^%\n]+\{', rest)
            if block_start is not None:
                close = source.find('%}', position + block_start.end())
                end = len(source) if close < 0 else close + 2
        if end is not None:
            pieces.append(source[position:end])
            position = end
            continue
        number = re.match(r'0[xX][0-9a-fA-F]+|0[bB][01]+|[0-9]+', rest)
        word = re.match(r'\.?[A-Za-z_][A-Za-z_0-9]*', rest) if number is None else None
        if word is not None:
            token = word.group()
            position += len(token)
            if token.lower() in keywords:
                changed_keyword = True
                if style == 'upper':
                    token = token.upper()
                else:
                    letter = 0
                    mixed = []
                    for char in token:
                        if char.isalpha():
                            char = char.upper() if letter % 2 == 0 else char.lower()
                            letter += 1
                        mixed.append(char)
                    token = ''.join(mixed)
            pieces.append(token)
            if word.group().lower() == '.lang_opt':
                # NON_WS, STRING and option names/values are case-sensitive
                # data in this lexer state; only its directive was a keyword.
                close = source.find('\n', position)
                end = len(source) if close < 0 else close + 1
                pieces.append(source[position:end])
                position = end
        elif number is not None:
            token = number.group()
            pieces.append(token)
            position += len(token)
        else:
            pieces.append(source[position])
            position += 1
    return ''.join(pieces) if changed_keyword else None


def expand_cases(base_cases, keywords):
    for case in base_cases:
        yield case
        for style in ('upper', 'mixed'):
            source = case_variant(case['source'], keywords, style)
            if source is not None:
                yield {**case, 'name': case['name'] + '/keywords-' + style, 'source': source}


def metadata(header):
    result = []
    for name, body in re.findall(r'static const struct pio_program (\w+)_program = \{(.*?)\};', header, re.S):
        version = int(re.search(r'#define ' + name + r'_pio_version (\d+)', header).group(1))
        ranges = int(re.search(r'\.used_gpio_ranges = (0x[0-9a-f]+)', body).group(1), 16)
        origin = int(re.search(r'\.origin = (-?\d+)', body).group(1))
        wrap = int(re.search(r'#define ' + name + r'_wrap (-?\d+)', header).group(1))
        wrap_target = int(re.search(r'#define ' + name + r'_wrap_target (\d+)', header).group(1))
        body = re.search(r'static inline pio_sm_config ' + name + r'_program_get_default_config\(.*?\) \{(.*?)\n\}', header, re.S).group(1)
        side_set = 'null'
        side = re.search(r'sm_config_set_sideset\(&c, (\d+), (\w+), (\w+)\)', body)
        if side:
            optional = side.group(2) in ('true', '1')
            pindirs = side.group(3) in ('true', '1')
            side_set = f'.{{ .count = {int(side.group(1)) - optional}, .optional = {str(optional).lower()}, .pindir = {str(pindirs).lower()} }}'
        fields = []
        for kind in ('in', 'out'):
            count = re.search(r'sm_config_set_' + kind + r'_pin_count\(&c, (\d+)\)', body)
            shift = re.search(r'sm_config_set_' + kind + r'_shift\(&c, (\w+), (\w+), (\d+)\)', body)
            if count:
                fields.append('.' + kind + ' = .{ .count = ' + count.group(1) + ', .right = ' + ('true' if shift.group(1) in ('true', '1') else 'false') + ', .auto = ' + ('true' if shift.group(2) in ('true', '1') else 'false') + ', .threshold = ' + shift.group(3) + ' }')
        count = re.search(r'sm_config_set_set_pin_count\(&c, (\d+)\)', body)
        if count:
            fields.append('.set = ' + count.group(1))
        fifo = re.search(r'sm_config_set_fifo_join\(&c, PIO_FIFO_JOIN_(\w+)\)', body)
        if fifo:
            fields.append('.fifo = .' + fifo.group(1).lower())
        status = re.search(r'sm_config_set_mov_status\(&c, STATUS_(\w+), (\d+)\)', body)
        if status:
            source = {'TX_LESSTHAN': 'txfifo', 'RX_LESSTHAN': 'rxfifo', 'IRQ_INDEX': 'irq'}[status.group(1)]
            n = int(status.group(2))
            block = ('this', 'prev', 'next')[n // 8] if source == 'irq' else 'this'
            fields.append(f'.mov_status = .{{ .source = .{source}, .n = {n % 8 if source == "irq" else n}, .block = .{block} }}')
        div = re.search(r'sm_config_set_clkdiv_int_frac\(&c, (\d+), (\d+)\)', body)
        if div:
            fields.append(f'.clock_div = {int(div.group(1)) + int(div.group(2)) / 256}')
        result.append(f'.{{ .pio_version = {version}, .used_gpio_ranges = {ranges}, .origin = {origin}, .wrap = {wrap}, .wrap_target = {wrap_target}, .side_set = {side_set}, .config = .{{ ' + ', '.join(fields) + ' } }')
    return '&.{ ' + ', '.join(result) + ' }'


def main():
    pioasm, corpus_path, output_path, lexer_path = sys.argv[1:]
    corpus_bytes = Path(corpus_path).read_bytes()
    base_cases = json.loads(corpus_bytes)
    keywords = keyword_spellings(lexer_path)
    cases = list(expand_cases(base_cases, keywords))
    names = set()
    lines = [
        '// Generated by tools/regen-pio-headers.sh --corpus; do not edit.',
        'const assembler = @import("../assembler.zig");',
        'pub const Metadata = struct { pio_version: u1, used_gpio_ranges: u3, origin: i32, wrap: i32, wrap_target: u5, side_set: ?assembler.encoder.SideSet, config: assembler.Config };',
        'pub const Case = struct {',
        '    version: u1,',
        '    requires_v1: bool,',
        '    metadata: []const Metadata,',
        '    name: []const u8,',
        '    source: []const u8,',
        '    words: ?[]const u16,',
        '};',
        'pub const corpus_hash = [_]u8{ ' + ', '.join(str(b) for b in hashlib.sha256(corpus_bytes).digest()) + ' };',
        'pub const cases = [_]Case{',
    ]
    accepted = 0
    with tempfile.TemporaryDirectory(prefix='pio-corpus-') as directory:
        source = Path(directory) / 'case.pio'
        header = Path(directory) / 'case.pio.h'
        for case in cases:
            if case['name'] in names:
                raise ValueError('duplicate corpus name: ' + case['name'])
            names.add(case['name'])
            source.write_text(case['source'])
            result = subprocess.run(
                [pioasm, '-v', str(case.get('version', 0)), '-o', 'c-sdk', str(source), str(header)],
                capture_output=True, text=True, timeout=10, cwd=directory,
            )
            # pioasm aborts on some invalid programs (e.g. duplicate names).
            # Any nonzero exit rejects the program; our assembler must return
            # a located error rather than reproducing the reference's crash.
            if result.returncode < 0:
                print(f"pioasm signal {-result.returncode} on {case['name']}: recorded as rejected", file=sys.stderr)
            words = None
            meta = '&.{}'
            if result.returncode == 0:
                accepted += 1
                meta = metadata(header.read_text())
                words = []
                arrays = re.findall(r'static const uint16_t \w+_program_instructions\[\] = \{(.*?)\};', header.read_text(), re.S)
                for array in arrays:
                    words.extend(int(word, 16) for word in re.findall(r'^\s*(0x[0-9a-fA-F]+),', array, re.M))
            literal = 'null' if words is None else '&.{ ' + ', '.join(f'0x{word:04x}' for word in words) + ' }'
            if words == []:
                literal = '&.{}'
            elif words is not None and len(words) == 1:
                literal = f'&.{{0x{words[0]:04x}}}'
            lines.append('    .{ .name = ' + json.dumps(case['name'], ensure_ascii=False) + ', .source = ' + json.dumps(case['source'], ensure_ascii=False) + ', .version = ' + str(case.get('version', 0)) + ', .requires_v1 = ' + str(case.get('requires_v1', False)).lower() + ', .metadata = ' + meta + ', .words = ' + literal + ' },')
    lines.append('};')
    Path(output_path).write_text('\n'.join(lines) + '\n')
    print(f'Corpus: {len(base_cases)} base programs, {len(cases)} total cases ({accepted} accepted, {len(cases) - accepted} rejected)')


if __name__ == '__main__':
    main()
