module dimportsort;

import std.algorithm : cmp, copy, count, equal, map, setIntersection, sort, uniq;
import std.array : array, join;
import std.format : format;
import std.stdio : writeln;
import std.string : empty, strip;

import dparse.ast;
import dparse.lexer : getTokensForParser, LexerConfig, str, StringCache;
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
      if (importGroups.empty ||
          !isConsective(declGroups[$-1][$-1], decl)) {
        declGroups ~= [decl];
        importGroups ~= toIdentifiers(decl);
        return;
      }
      declGroups[$-1] ~= decl;
      importGroups[$-1] ~= toIdentifiers(decl);      
    }
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
  
  struct Output {
    string mod;
    string[] binds;
    string[] attrs;

    bool canMerge(Output that) const {
      return this.mod == that.mod && equal(this.attrs, that.attrs);
    }
  }

  string outputImports(ImportIdentifiers[] idents, string indent = "") const {
    import std.range : chain, only;
    // TODO: support max line length.
    sort(idents);
    // Merge redundant modules.
    Output[] outputs;
    foreach (id; idents) {
      auto attrs = id.attrs.array.dup;
      sort(attrs);
      auto o = Output(id.name, id.bindNames.array.dup, attrs);
      if (outputs.empty || !outputs[$-1].canMerge(o)) {
        outputs ~= o;
        continue;
      }
      outputs[$-1].binds ~= o.binds;
    }
    
    string ret;
    foreach (o; outputs) {
      ret ~= indent;
      if (!o.attrs.empty) {
        ret ~= o.attrs.join(" ") ~ " ";
      }
      ret ~= "import " ~ o.mod;
      if (!o.binds.empty) {
        sort(o.binds);
        ret ~= " : " ~ o.binds.uniq.join(", ");
      }
      ret ~= ";\n";
    }
    // Remove the last new line (\n).
    return ret[0 .. $-1];
  }
  
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
  this(const Attribute[] attributes, const SingleImport si,
       const ImportBind[] binds = []) {
    this.attributes = attributes;
    this.singleImport = si;
    this.binds = binds;
  }
  
  const Attribute[] attributes;
  const SingleImport singleImport;
  const ImportBind[] binds;

  pure nothrow @safe
  string name() const {
    return singleImport.identifierChain.identifiers.map!"a.text".join(".");
  }

  pure nothrow @safe
  auto bindNames() const {
    return binds.map!"a.left.text";
  }

  auto attrs() const {
    return attributes.map!(a => str(a.attribute.type));
  }

  pure @safe
  override string toString() const {
    return format!"%s(name=%s, binds=%s)"(typeof(this).stringof, name, bindNames);
  }

  int opCmp(ImportIdentifiers that) const {
    // First sort by the module name w/o attrs.
    auto ret = cmp(this.name, that.name); 
    if (ret != 0) {
      return ret;
    }
    // Then sort by attrs.
    return cmp(this.attrs.join(" "), that.attrs.join(" "));
  }
}

/// Test for binding.
unittest {
  auto visitor = visitImports(q{
      import foo : aa, bb, cc;
    });
  assert(visitor.importGroups[0][0].name == "foo");
  assert(equal(visitor.importGroups[0][0].bindNames, ["aa", "bb", "cc"]));
}

/// Decomposes multi module import decl to a list of single module with binds.
ImportIdentifiers[] toIdentifiers(const Declaration decl) {
  auto idecl = decl.importDeclaration;
  assert(idecl !is null, "not import declaration.");
  auto ret = idecl.singleImports.map!(
      x => new ImportIdentifiers(decl.attributes, x)).array;
  if (auto binds = idecl.importBindings) {
    ret ~= new ImportIdentifiers(
        decl.attributes, binds.singleImport, binds.importBinds);
  }
  return ret;
}

/// Test for import attributes.
unittest {
  auto visitor = visitImports(q{
      public import foo;
      public static import bar;
    });
  auto ids = visitor.importGroups[0];
  assert(ids[0].name == "foo");
  assert(equal(ids[0].attrs, ["public"]));
  assert(ids[1].name == "bar");
  assert(equal(ids[1].attrs, ["public", "static"]));
}

/// Test for multiple modules and binding.
unittest {
  auto visitor = visitImports(q{
      import foo, bar : aa, bb, cc;
    });
  auto ids = visitor.importGroups[0];
  assert(ids[0].name == "foo");
  assert(ids[0].bindNames.empty);
  assert(ids[1].name == "bar");
  assert(equal(ids[1].bindNames, ["aa", "bb", "cc"]));

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

/// Test for modules with attributes.
unittest {
  auto visitor = visitImports(q{
      import foo : bar;
      static import foo;
      public import foo : bar;
      public import foo : baz;
      import bar;
    });
  writeln(visitor.outputImports(visitor.importGroups[0]));
  assert(visitor.outputImports(visitor.importGroups[0]) == q{
import bar;
import foo : bar;
public import foo : bar, baz;
static import foo;
    }.strip);
}
