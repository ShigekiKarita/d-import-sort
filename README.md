# d-import-sort

A tool for sorting import declarations in D.

## Usage

```bash
$ dub fetch d-import-sort
$ dub run d-import-sort <files>
<<<<filename:minline-maxline
unsorted imports
...
----
sorted imports
...
>>>>
...
```

Example

```bash
$ dub run -- ./source/dimportsort.d

<<<<./source/dimportsort.d:2-7
import std.algorithm : cmp, count, copy, map, setIntersection, sort;
import std.array : array, join;
import std.format : format;
import std.stdio : writeln;
import std.string : empty;
----
import std.algorithm : cmp, copy, count, map, setIntersection, sort;
import std.array : array, join;
import std.format : format;
import std.stdio : writeln;
import std.string : empty;
>>>>
<<<<./source/dimportsort.d:68-71
    import std.algorithm : find;
    import std.range : drop, take;
    import std.algorithm : maxElement, minElement, joiner, splitter;
----
    import std.algorithm : find;
    import std.algorithm : joiner, maxElement, minElement, splitter;
    import std.range : drop, take;
>>>>
```

## TODO

- [x] parse import
- [x] simple sorted output
- [ ] color output
- [ ] `diff` format output
- [ ] max line length
