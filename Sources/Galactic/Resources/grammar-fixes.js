/*
  Corrections to two upstream highlight.js grammars, applied as the grammar
  files register themselves.

  Both files stay stock — this wraps `registerLanguage`, sees the definition on
  its way in, and prepends rules that match before the ones already there.
  Nothing here edits an existing rule: upstream numbers its capture groups
  across a `match` array and a scope map reads those numbers, so rewriting one
  of their patterns silently shifts every index after it.

  What is fixed, both reported against 11.11.1:

  1. A Ruby class or module name ending in capitals is truncated. The name
     pattern is an alternation whose first branch — "ends in lowercase" — is
     tried first and succeeds on the shorter prefix, so the branch written for
     names ending in capitals is unreachable. `module LdotRB` scopes `Ldot` and
     leaves `RB` unscoped. Swapping the branches is not the fix: it breaks
     `FooBar` down to `FooB`. One pattern with an optional capital tail is.

  2. Neither the Ruby nor the Crystal grammar knows a method definition can
     name a receiver. `def self.settings` scopes `self` as the method name and
     leaves `.settings` and its parameters unscoped.
*/
(function () {
  if (typeof hljs === "undefined" || hljs.__galaxyGrammarFixes) { return; }

  // A Ruby/Crystal class name: capitalised words, optionally ending in an
  // all-capital run, optionally namespaced.
  var CLASS_NAME = /(?:[A-Z]+[a-z0-9]+)+[A-Z]*(?:::\w+)*/;
  // A method name, matching upstream's own definition of one.
  var METHOD_NAME = /(?:[a-zA-Z_]\w*[!?=]?|\[\]=?|<=>|[<>]=?|===?|[-+*/%^&|~]|\*\*)/;
  var RECEIVER = /self|(?:[A-Z]+[a-z0-9]+)+[A-Z]*/;

  // `def <receiver>.<name>` — the name is the title, the receiver is not.
  //
  // `def` is scoped here rather than left to keyword matching. The class rule
  // below gets its keyword either way, this one does not, and a rule that
  // depends on which is not a rule worth keeping.
  function receiverMethodRule(keywords) {
    return {
      match: [/\bdef/, /\s+/, RECEIVER, /\./, METHOD_NAME],
      scope: { 1: "keyword", 3: "variable.language", 5: "title.function" },
      keywords: keywords,
    };
  }

  // `class Foo` / `module Foo`, with the whole name.
  //
  // Both of upstream's forms, because matching only the simple one would win
  // the race against its own inheritance variant and cost `class Foo < Bar`
  // the scope that marks the superclass.
  function classNameRule(keywords) {
    return {
      variants: [
        { match: [/\bclass/, /\s+/, CLASS_NAME, /\s+<\s+/, CLASS_NAME] },
        { match: [/\b(?:class|module)/, /\s+/, CLASS_NAME] },
      ],
      scope: {
        1: "keyword",
        3: "title.class",
        5: "title.class.inherited",
      },
      keywords: keywords,
    };
  }

  var applied = [];

  function fix(name, language) {
    if (!language || !Array.isArray(language.contains)) { return language; }
    var rules = [];
    if (name === "ruby") {
      rules = [
        receiverMethodRule(language.keywords),
        classNameRule(language.keywords),
      ];
    } else if (name === "crystal") {
      rules = [receiverMethodRule(language.keywords)];
    }
    if (!rules.length) { return language; }
    language.contains = rules.concat(language.contains);
    applied.push(name);
    return language;
  }

  var register = hljs.registerLanguage.bind(hljs);
  hljs.registerLanguage = function (name, factory) {
    return register(name, function (instance) {
      return fix(name, factory(instance));
    });
  };

  // Readable from outside so a test can assert the corrections are still
  // reaching the grammars rather than quietly doing nothing.
  hljs.__galaxyGrammarFixes = applied;
})();
