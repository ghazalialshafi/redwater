import ../src/redwater
assert sha1Hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d"
assert sha1Hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
assert sha1Hex("The quick brown fox jumps over the lazy dog") == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"
var big = newString(1000)
assert sha1Hex(big).len == 40
echo "ok"
