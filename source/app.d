module app;

import std.file : readText;
import std.stdio : writeln;

import dimportsort;

int main(string[] args) {
  if (args.length == 0) {
    writeln("Usage: ", args[0], " <filepath> ...");
    return 1;
  }

  foreach (fileName; args[1 .. $]) {
    auto sourceCode = readText(fileName);
    auto visitor = visitImports(sourceCode, fileName);
    writeln(visitor.diff());
  }
  return 0;
}
