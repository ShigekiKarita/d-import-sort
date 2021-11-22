module dimportsort;

import std.algorithm : cmp, copy, count, map, setIntersection, sort, uniq;
import std.array : array, join;
import std.format : format;
import std.stdio : writeln;
import std.string : empty;

import dparse.ast;
import dparse.lexer;
import dparse.parser : parseModule;
import dparse.rollback_allocator : RollbackAllocator;


///
class ImportVisitor : ASTVisitor {

  ///
  this(string sourceCode) {
    this.cache = StringCache(StringCache.defaultBucketCount);
    this.sourceCode = sourceCode;
  }

  alias visit = ASTVisitor.visit;

  /** Visit import declaration.

   Params:
     decl = import declaration.

   Syntax:

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
  override void visit(const ImportDeclaration decl) {
    if (importGroups.empty ||
        !isConsective(declGroups[$-1][$-1], decl)) {
      declGroups ~= [decl];
      importGroups ~= toIdentifiers(decl);
      return;
    }
    declGroups[$-1] ~= decl;
    importGroups[$-1] ~= toIdentifiers(decl);

    decl.accept(this);
  }

  struct Output {
    string mod;
    string[] binds;
  }

  pure @safe
  string outputImports(ImportIdentifiers[] idents, string indent = "") const {
    // TODO: support max line length.
    sort(idents);
    // Merge redundant modules.
    Output[] outputs;
    foreach (id; idents) {
      if (outputs.empty || outputs[$-1].mod != id.name) {
        outputs ~= Output(id.name, id.bindNames);
        continue;
      }
      outputs[$-1].binds ~= id.bindNames;
    }
    
    string ret;
    foreach (o; outputs) {
      ret ~= indent ~ "import " ~ o.mod;
      if (!o.binds.empty) {
        sort(o.binds);
        ret ~= " : " ~ o.binds.uniq.join(", ");
      }
      ret ~= ";\n";
    }
    // Remove the last new line (\n).
    return ret[0 .. $-1];
  }

  string diff() {
    import std.algorithm : find;
    import std.range : drop, take;
    import std.algorithm : maxElement, minElement, joiner, splitter;

    string ret;
    foreach (i, decls; declGroups) {
      auto lines = decls.map!(d => d.tokens.map!(t => t.line)).joiner;
      auto min = lines.minElement - 1;
      auto max = lines.maxElement;
      auto input = sourceCode.splitter('\n').drop(min).take(max - min).join("\n");

      auto indent = input[0 .. $ - input.find("import").length];
      auto output = outputImports(importGroups[i], indent);
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
  const(ImportDeclaration)[][] declGroups;
  ImportIdentifiers[][] importGroups;

  // For ownerships of tokens.
  RollbackAllocator rba;
  StringCache cache;
}

/// Checks import declarations are consective.
@nogc nothrow pure @safe
bool isConsective(const ImportDeclaration a, const ImportDeclaration b) {
  return !setIntersection(a.tokens.map!"a.line + 1", b.tokens.map!"a.line").empty;
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

/// Data type for identifiers in an import declaration.
/// import mod : binds, ...;
class ImportIdentifiers {
  this(const SingleImport si, const ImportBind[] binds = []) {
    this.singleImport = si;
    this.binds = binds;
  }

  const SingleImport singleImport;
  const ImportBind[] binds;

  pure nothrow @safe
  string name() const {
    return singleImport.identifierChain.identifiers.map!"a.text".join(".");
  }

  pure nothrow @safe
  string[] bindNames() const {
    auto ret = new string[binds.length];
    copy(binds.map!"a.left.text", ret);
    sort(ret);
    return ret;
  }

  pure @safe
  override string toString() const {
    return format!"%s(name=%s, binds=%s)"(typeof(this).stringof, name, bindNames);
  }

  nothrow pure @safe
  int opCmp(ImportIdentifiers that) const {
    return cmp(this.name, that.name);
  }
}

/// Test for binding.
unittest {
  auto visitor = visitImports(q{
      import foo : aa, cc, bb;
    });
  assert(visitor.importGroups[0][0].name == "foo");
  assert(visitor.importGroups[0][0].bindNames == ["aa", "bb", "cc"]);
}

/// Decomposes multi module import decl to a list of single module with binds.
ImportIdentifiers[] toIdentifiers(const ImportDeclaration decl) {
  auto ret = decl.singleImports.map!(x => new ImportIdentifiers(x)).array;
  if (auto binds = decl.importBindings) {
    ret ~= new ImportIdentifiers(binds.singleImport, binds.importBinds);
  }
  return ret;
}

/// Test for multiple modules and binding.
unittest {
  auto visitor = visitImports(q{
      import foo, bar : aa, cc, bb;
    });
  auto ids = visitor.importGroups[0];
  assert(ids[0].name == "foo");
  assert(ids[0].bindNames == []);
  assert(ids[1].name == "bar");
  assert(ids[1].bindNames == ["aa", "bb", "cc"]);

  // Test opCmp in sort.
  sort(ids);
  assert(ids[0].name == "bar");
  assert(ids[1].name == "foo");
}

/// Test for merging redundant modules.
unittest {
  auto visitor = visitImports(q{
      import foo : bar;
      import foo : baz, bar;
    });
  assert(visitor.outputImports(visitor.importGroups[0]) ==
         "import foo : bar, baz;");
}
