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
$ dub run -- ./source/*.d

<<<<./source/app.d:2-5
import std.string : empty;
import std.stdio : writeln;
import std.file : readText;
----
import std.file : readText;
import std.stdio : writeln;
import std.string : empty;
>>>>

<<<<./source/dimportsort.d:89-92
    import std.algorithm : find;
    import std.range : drop, take;
    import std.algorithm : maxElement, minElement, joiner, splitter;
----
    import std.algorithm : find, joiner, maxElement, minElement, splitter;
    import std.range : drop, take;
>>>>
```

## TODO

- [ ] fully support import declarations
  - [x] single import e.g. `import foo;`
  - [x] multiple import e.g. `import foo, bar;`
  - [x] selective import e.g. `import foo : bar;`
  - [x] public import e.g. `public import foo;`
  - [x] static import e.g. `static import foo;`
  - [ ] renamed import e.g. `import foo = bar;`
- [x] simple sorted output
- [x] merge imports for redundant modules
- [ ] option for overwriting files
- [ ] color output
- [ ] `diff` format output
- [ ] max line length

## Links

- https://dlang.org/spec/module.html
- https://libdparse.dlang.io/grammar.html#importDeclaration