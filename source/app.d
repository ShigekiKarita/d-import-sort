module app;

import dimportsort;
import std.file : readText;
import std.stdio : writeln;
import std.string : empty;

int main(string[] args) {
  if (args.length == 0) {
    writeln("Usage: ", args[0], " <filepath> ...");
    return 1;
  }

  foreach (fileName; args[1 .. $]) {
    auto sourceCode = readText(fileName);
    auto visitor = visitImports(sourceCode, fileName);
    auto diff = visitor.diff();
    if (!diff.empty) writeln(diff);
  }
  return 0;
}
