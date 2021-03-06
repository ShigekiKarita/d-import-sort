module dimportsort;

import dparse.ast;
import dparse.lexer : getTokensForParser, LexerConfig, str, StringCache;
import dparse.parser : parseModule;
import dparse.rollback_allocator : RollbackAllocator;
import std.algorithm : cmp, copy, count, equal, map, setIntersection, sort, uniq;
import std.array : array, join;
import std.format : format;
import std.stdio : writeln;
import std.string : empty, strip;
import std.uni : sicmp;

///
class ImportVisitor : ASTVisitor {

  ///
  @nogc nothrow pure
  this(string sourceCode) {
    this.cache = StringCache(StringCache.defaultBucketCount);
    this.sourceCode = sourceCode;
  }

  alias visit = ASTVisitor.visit;

  /**
     Syntax:

     declaration:
       | attribute* declaration2
       | attribute+ '{' declaration* '}'
       ;
     attribute:
       | public
       | private
       | protected
       | package
       | static
       | ...
       ;
     declaration2:
       | importDeclaration
       | ...
       ;

     importBind:
       Identifier ('=' Identifier)?
       ;
     importBindings:
       singleImport ':' importBind (',' importBind)*
       ;
     importDeclaration:
       | 'import' singleImport (',' singleImport)* (',' importBindings)? ';'
       | 'import' importBindings ';'
       ;
   */
  override void visit(const Declaration decl) {
    decl.accept(this);
    if (auto idecl = decl.importDeclaration) {
      if (importGroups.empty || !isConsective(declGroups[$-1][$-1], decl)) {
        declGroups ~= [decl];
        importGroups ~= toIdentifiers(decl);
        return;
      }
      declGroups[$-1] ~= decl;
      importGroups[$-1] ~= toIdentifiers(decl);
    }
  }

  /// Returns: diff patch to sort import declarations (WIP).
  @safe pure
  string diff() {
    import std.algorithm : find, joiner, maxElement, minElement, splitter;
    import std.range : drop, take;

    string ret;
    foreach (i, decls; declGroups) {
      auto lines = decls.map!(d => d.tokens.map!(t => t.line)).joiner;
      auto min = minElement(lines) - 1;
      auto max = maxElement(lines);
      auto input = sourceCode.splitter('\n').drop(min).take(max - min)
          .join("\n");

      auto indent = input[0 .. $ - input.find("import").length];
      auto output = formatSortedImports(sortedImports(importGroups[i]), indent);
      if (input == output) continue;

      ret ~= format!"<<<<%s:%d-%d\n"(fileName, min, max)
          ~ input ~ "\n"
          ~ "----\n"
          ~ output ~ "\n"
          ~ ">>>>\n";
    }
    return ret;
  }

 private:
  string sourceCode;
  string fileName;
  const(Declaration)[][] declGroups;
  ImportIdentifiers[][] importGroups;

  // For ownerships of tokens.
  RollbackAllocator rba;
  StringCache cache;
}

/// Checks declarations are consective.
@nogc nothrow pure @safe
bool isConsective(const Declaration a, const Declaration b) {
  return !setIntersection(a.tokens.map!"a.line + 1", b.tokens.map!"a.line")
      .empty;
}

ImportVisitor visitImports(string sourceCode, string fileName = "unittest") {
  auto visitor = new ImportVisitor(sourceCode);
  LexerConfig config;
  auto tokens = getTokensForParser(sourceCode, config, &visitor.cache);
  auto m = parseModule(tokens, fileName, &visitor.rba);
  visitor.visit(m);
  visitor.fileName = fileName;
  return visitor;
}

/// Test for diff outputs.
unittest {
  auto visitor = visitImports(q{
    import cc;
    import ab;
    import aa.cc;
    import aa.bb;

import foo;
import bar, bar2;  // expands to two imports.

    void main() {}
    });
  assert(visitor.declGroups.length == 2);
  assert(visitor.declGroups[0].length == 4);
  assert(visitor.declGroups[1].length == 2);

  assert(visitor.importGroups.length == 2);
  assert(visitor.importGroups[0].length == 4);
  assert(visitor.importGroups[1].length == 3);

  assert(visitor.diff ==
`<<<<unittest:1-5
    import cc;
    import ab;
    import aa.cc;
    import aa.bb;
----
    import aa.bb;
    import aa.cc;
    import ab;
    import cc;
>>>>
<<<<unittest:6-8
import foo;
import bar, bar2;  // expands to two imports.
----
import bar;
import bar2;
import foo;
>>>>
`);
}

nothrow pure @safe
string attributeStringOf(const Attribute attr) {
  auto s = str(attr.attribute.type);
  if (s != "package") return s;
  return "package("
      ~ attr.identifierChain.identifiers.map!"a.text".join(".")
      ~ ")";
}

/// Test for import attributes.
unittest {
  auto visitor = visitImports(q{
      public import foo;
      public static import bar;
      package(std.regex) import baz;
    });
  auto ids = visitor.importGroups[0];
  assert(ids[0].fullName == "foo");
  assert(equal(ids[0].attrs, ["public"]));
  assert(ids[1].fullName == "bar");
  assert(equal(ids[1].attrs, ["public", "static"]));
  assert(ids[2].fullName == "baz");
  assert(equal(ids[2].attrs, ["package(std.regex)"]));
}

/// Data type for identifiers in an import declaration.
/// import mod : binds, ...;
class ImportIdentifiers {
  @nogc nothrow pure @safe
  this(const Attribute[] attributes, const SingleImport si,
       const ImportBind[] binds = []) {
    this.attributes = attributes;
    this.singleImport = si;
    this.binds = binds;
  }

  const Attribute[] attributes;
  const SingleImport singleImport;
  const ImportBind[] binds;

  nothrow pure @safe
  string fullName() const {
    string prefix = singleImport.rename.text;
    if (!prefix.empty) {
      prefix ~= " = ";
    }
    return prefix ~ names().join(".");
  }

  @nogc nothrow pure @safe
  auto names() const {
    return singleImport.identifierChain.identifiers.map!"a.text";
  }

  @nogc nothrow pure @safe
  auto bindNames() const {
    return binds.map!(b => b.left.text ~
                      (b.right.text.empty ? "" : " = " ~ b.right.text));
  }

  nothrow pure @safe
  auto attrs() const {
    return attributes.map!attributeStringOf;
  }

  /// Returns: string for debugging.
  pure @safe
  override string toString() const {
    return format!"%s(name=\"%s\", binds=\"%s\")"(
        typeof(this).stringof, fullName, bindNames);
  }

  nothrow pure @safe
  private string cmpName() const {
    const rename = singleImport.rename.text;
    return rename.empty ? fullName : rename;
  }

  /// Compares identifiers for sorting.
  nothrow pure @safe
  int opCmp(ImportIdentifiers that) const {
    // First sort by the module name w/o attrs. Note that in D-Scanner,
    // dscanner/analysis/imports_sortedness.d uses sicmp instead of cmp.
    auto ret = sicmp(this.fullName, that.fullName);
    if (ret != 0) {
      return ret;
    }
    // Then sort by attrs. cmp is OK because attributes are always lowercased.
    return cmp(this.attrs, that.attrs);
  }
}

/// Test for selective imports.
unittest {
  auto visitor = visitImports(q{
      import foo : aa, bb, cc;
    });
  assert(visitor.importGroups[0][0].fullName == "foo");
  assert(equal(visitor.importGroups[0][0].bindNames, ["aa", "bb", "cc"]));
}

/// Test for renamed imports.
unittest {
  auto visitor = visitImports(q{
      import foo = bar;
      import bar = foo;
      import baz.foo;
      import zz : f = foo;
    });
  // Sorting is based on the renamed name if exists.
  sort(visitor.importGroups[0]);
  assert(visitor.importGroups[0][0].fullName == "bar = foo");
  assert(visitor.importGroups[0][1].fullName == "baz.foo");
  assert(visitor.importGroups[0][2].fullName == "foo = bar");
  assert(visitor.importGroups[0][3].fullName == "zz");
}

/// Decomposes multi module import decl to a list of single module with binds.
ImportIdentifiers[] toIdentifiers(const Declaration decl) {
  const idecl = decl.importDeclaration;
  assert(idecl !is null, "not import declaration.");
  auto ret = idecl.singleImports.map!(
      x => new ImportIdentifiers(decl.attributes, x)).array;
  if (auto binds = idecl.importBindings) {
    ret ~= new ImportIdentifiers(
        decl.attributes, binds.singleImport, binds.importBinds);
  }
  return ret;
}

/// Test for multiple modules and binding.
unittest {
  auto visitor = visitImports(q{
      import foo,
          bar : aa, bb,
          cc;
    });
  auto ids = visitor.importGroups[0];
  assert(ids[0].fullName == "foo");
  assert(ids[0].bindNames.empty);
  assert(ids[1].fullName == "bar");
  assert(equal(ids[1].bindNames, ["aa", "bb", "cc"]));
}

// Test opCmp in sort.
unittest {
  auto visitor = visitImports(q{
      import foo.bar;
      import foo, bar : aa, bb, cc;
      static import foo.bar;
    });
  auto ids = visitor.importGroups[0];
  sort(ids);
  assert(ids[0].fullName == "bar");
  assert(ids[1].fullName == "foo");
  assert(ids[2].fullName == "foo.bar");
  assert(ids[3].fullName == "foo.bar");
  assert(equal(ids[3].attrs, ["static"]));
}

/// Data type to store a sorted import declaration.
struct SortedImport {
  string mod;
  // These must be sorted.
  string[] binds;
  string[] attrs;
}

/// Checks if two sorted imports can be merged into one.
@nogc nothrow pure @safe
bool canMerge(SortedImport a, SortedImport b) {
  return a.mod == b.mod
      && equal(a.attrs, b.attrs)  // Cannot merge diff attributes.
      && (a.binds.empty == b.binds.empty);  // Both selective or non-selective.
}

unittest {
  assert(SortedImport("a").canMerge(SortedImport("a")));
  assert(SortedImport("a", ["b"]).canMerge(SortedImport("a", ["c"])));
  assert(!SortedImport("a", ["b"]).canMerge(SortedImport("a", [])));
  assert(SortedImport("a", [], ["public"]).canMerge(
      SortedImport("a", [], ["public"])));
  assert(!SortedImport("a", [], []).canMerge(
      SortedImport("a", [], ["public"])));
}

/// Merges and sorts import identifiers for outputs.
pure @safe
SortedImport[] sortedImports(ImportIdentifiers[] idents) {
  import std.range : chain, only;
  import std.string : split;

  // TODO: support max line length.
  sort(idents);
  // Merge redundant modules.
  SortedImport[] outputs;
  foreach (id; idents) {
    auto attrs = id.attrs.array.dup;
    sort(attrs);
    auto o = SortedImport(id.fullName, id.bindNames.array.dup, attrs);
    if (outputs.empty || !outputs[$-1].canMerge(o)) {
      outputs ~= o;
      continue;
    }
    outputs[$-1].binds ~= o.binds;
  }
  foreach (ref o; outputs) {
    o.binds = sort!((a, b) => sicmp(a, b) < 0)(o.binds)
                    .uniq.array;
  }
  return outputs;
}

// Test with renamed selective imports.
unittest {
  auto visitor = visitImports(q{
      import foo : bar = foo;
      import foo : zoo = bar;
      import foo : baaz;
      import foo : aar;
    });
  assert(sortedImports(visitor.importGroups[0]).formatSortedImports ==
         "import foo : aar, baaz, bar = foo, zoo = bar;");
}

/// Formats output imports into a string.
nothrow pure @safe
string formatSortedImports(SortedImport[] outputs, string indent = "") {
  string ret;
  foreach (o; outputs) {
    ret ~= indent;
    if (!o.attrs.empty) {
      ret ~= o.attrs.join(" ") ~ " ";
    }
    ret ~= "import " ~ o.mod;
    if (!o.binds.empty) {
      ret ~= " : " ~ o.binds.join(", ");
    }
    ret ~= ";\n";
  }
  // Remove the last new line (\n).
  return ret[0 .. $-1];
}

/// Test for merging redundant modules.
unittest {
  auto visitor = visitImports(q{
      import foo : bar;
      import foo : baz, bar;
    });
  assert(sortedImports(visitor.importGroups[0]).formatSortedImports ==
         "import foo : bar, baz;");
}

/// Test for modules with attributes.
unittest {
  auto visitor = visitImports(q{
      import foo : bar;
      static import foo;
      public import foo : bar;
      public import foo : baz;
      import bar;
    });
  assert(sortedImports(visitor.importGroups[0]).formatSortedImports == q{
import bar;
import foo : bar;
public import foo : bar, baz;
static import foo;
    }.strip);
}
