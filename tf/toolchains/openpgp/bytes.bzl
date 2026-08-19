"""Turning what `ctx.read` hands back into byte values Starlark can compute on.

Bazel reads a file as Latin-1, so `module_ctx.read` on a binary file round-trips
every byte as the character of the same value: a 566-byte signature comes back
as 566 characters. That is the only reason verifying a signature in Starlark is
possible at all, since Starlark has neither `ord` nor `chr`, and rejects `\\x`
escapes outright. Octal escapes are what it does accept, so the table below is
written that way and is the whole bridge from characters to numbers.

Everything above this layer works on a list of ints, which is also what makes it
testable: a fixture can be written as hex rather than as escaped binary.
"""

# Every byte from 0 to 255, in order, so that a character's index in this string
# is its value. Generated, and asserted against by bytes_test.bzl rather than
# read by eye.
_ALL_BYTES = (
    "\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\040\041\042\043\044\045\046\047\050\051\052\053\054\055\056\057\060\061\062\063\064\065\066\067\070\071\072\073\074\075\076\077" +
    "\100\101\102\103\104\105\106\107\110\111\112\113\114\115\116\117\120\121\122\123\124\125\126\127\130\131\132\133\134\135\136\137\140\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157\160\161\162\163\164\165\166\167\170\171\172\173\174\175\176\177" +
    "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277" +
    "\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377"
)

_BYTE_VALUE = {c: i for i, c in enumerate(_ALL_BYTES.elems())}

_HEX_DIGITS = "0123456789abcdef"

_HEX_VALUE = {c: i for i, c in enumerate(_HEX_DIGITS.elems())}

def latin1_to_bytes(data):
    """Converts a string `ctx.read` returned into the byte values it holds.

    Args:
      data: the string, whose characters must all be U+0000 to U+00FF.

    Returns:
      A list of ints, one per character, each 0 to 255.
    """
    out = []
    for c in data.elems():
        value = _BYTE_VALUE.get(c)
        if value == None:
            fail("byte out of range while reading binary content: %r" % c)
        out.append(value)
    return out

def hex_to_bytes(text):
    """Converts a hex string to the byte values it spells.

    Whitespace is ignored, so a fixture can be wrapped across lines.

    Args:
      text: the hex, in either case, holding an even number of digits.

    Returns:
      A list of ints, one per byte pair.
    """
    digits = []
    for c in text.lower().elems():
        if c in [" ", "\n", "\t", "\r"]:
            continue
        value = _HEX_VALUE.get(c)
        if value == None:
            fail("not a hex digit: %r" % c)
        digits.append(value)

    if len(digits) % 2 != 0:
        fail("hex holds an odd number of digits: %d" % len(digits))

    return [digits[i] * 16 + digits[i + 1] for i in range(0, len(digits), 2)]

def bytes_to_int(data):
    """Reads a big-endian unsigned integer out of a byte list.

    Args:
      data: the bytes, most significant first.

    Returns:
      The integer they spell.
    """
    value = 0
    for b in data:
        value = value * 256 + b
    return value

def int_to_bytes(value, length):
    """Writes an unsigned integer as a fixed-width big-endian byte list.

    Args:
      value: the integer, which must fit in `length` bytes.
      length: how many bytes to write.

    Returns:
      A list of ints, most significant first.
    """
    out = [0] * length
    for i in range(length - 1, -1, -1):
        out[i] = value % 256
        value = value // 256
    if value != 0:
        fail("integer does not fit in %d bytes" % length)
    return out
