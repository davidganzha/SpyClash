import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceRoot = path.resolve(currentDirectory, "..");
const componentsDirectory = path.join(sourceRoot, "components");

async function loadI18nModule() {
  const ukTranslations = (await import(pathToFileURL(path.join(componentsDirectory, "i18n.uk.js")))).default;
  const source = fs.readFileSync(path.join(componentsDirectory, "i18n.jsx"), "utf8")
    .replace(
      /^import ukTranslations from "\.\/i18n\.uk";$/m,
      `const ukTranslations = ${JSON.stringify(ukTranslations)};`,
    );
  const dataURL = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`;
  return import(dataURL);
}

function sourceFiles(directory, result = []) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      sourceFiles(absolutePath, result);
    } else if (/\.[jt]sx?$/.test(entry.name)) {
      result.push(absolutePath);
    }
  }
  return result;
}

function parsedSource(file) {
  const source = fs.readFileSync(file, "utf8");
  const scriptKind = file.endsWith("x") ? ts.ScriptKind.JSX : ts.ScriptKind.JS;
  return {
    source,
    sourceFile: ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, scriptKind),
  };
}

test("Ukrainian catalogue has complete key and built-in word parity", async () => {
  const { translations, getT } = await loadI18nModule();
  const englishKeys = Object.keys(translations.en).sort();
  const ukrainianKeys = Object.keys(translations.uk).sort();

  assert.deepEqual(ukrainianKeys, englishKeys);

  for (const key of englishKeys) {
    if (key === "builtInCategories") continue;
    const englishValue = translations.en[key];
    const ukrainianValue = translations.uk[key];
    assert.equal(Array.isArray(ukrainianValue), Array.isArray(englishValue), key);
    assert.equal(typeof ukrainianValue, typeof englishValue, key);
    assert.deepEqual(
      JSON.parse(JSON.stringify(ukrainianValue, (_nestedKey, value) => typeof value === "string" ? "string" : value)),
      JSON.parse(JSON.stringify(englishValue, (_nestedKey, value) => typeof value === "string" ? "string" : value)),
      key,
    );
    if (typeof englishValue === "string") {
      const englishPlaceholders = englishValue.match(/\{[^{}]+\}/g)?.sort() || [];
      const ukrainianPlaceholders = ukrainianValue.match(/\{[^{}]+\}/g)?.sort() || [];
      assert.deepEqual(ukrainianPlaceholders, englishPlaceholders, `${key} placeholder parity`);
    }
    assert.deepEqual(getT("uk")(key), ukrainianValue, key);
  }

  const categories = Object.values(translations.uk.builtInCategories);
  assert.equal(categories.length, 9);
  assert.ok(categories.every((words) => Array.isArray(words) && words.length === 25));
  assert.equal(categories.flat().length, 225);
});

test("Ukrainian language normalization and direct copy never use English fallback", async () => {
  const { translations, localize, normalizeLanguage, supportedLanguages } = await loadI18nModule();

  assert.deepEqual([...supportedLanguages].sort(), ["en", "es", "ru", "uk"]);

  assert.equal(normalizeLanguage("uk"), "uk");
  assert.equal(normalizeLanguage("UK"), "uk");
  assert.equal(normalizeLanguage("uk-UA"), "uk");
  assert.equal(normalizeLanguage("uk_UA"), "uk");
  assert.equal(normalizeLanguage("ru-RU"), "ru");
  assert.equal(normalizeLanguage("es_MX"), "es");
  assert.equal(normalizeLanguage("en-GB"), "en");
  assert.equal(normalizeLanguage("ua"), "en");
  assert.equal(normalizeLanguage("ua-UA"), "en");
  assert.equal(normalizeLanguage("unsupported"), "en");
  assert.equal(localize("uk", "English", "Русский", "Українська"), "Українська");
  assert.equal(localize("es", "English", "Русский", "Українська", "Español"), "Español");

  const untranslated = Object.entries(translations.uk)
    .filter(([key, value]) => key !== "language" && typeof value === "string" && value === translations.en[key])
    .map(([key]) => key);
  assert.deepEqual(untranslated, []);
});

test("localized Web surfaces do not contain binary Russian versus English branches", () => {
  const offenders = [];
  const comparison = /\b(?:lang|language|locale\.language)\s*={2,3}\s*["']ru["']/g;

  for (const file of sourceFiles(sourceRoot)) {
    if (file.endsWith("i18n.jsx")) continue;
    const source = fs.readFileSync(file, "utf8");
    if (comparison.test(source)) offenders.push(path.relative(sourceRoot, file));
    comparison.lastIndex = 0;
  }

  assert.deepEqual(offenders, []);
});

test("every localize call supplies explicit Ukrainian copy", () => {
  const offenders = [];

  for (const file of sourceFiles(sourceRoot)) {
    const { sourceFile } = parsedSource(file);
    const visit = (node) => {
      if (
        ts.isCallExpression(node)
        && ts.isIdentifier(node.expression)
        && node.expression.text === "localize"
        && node.arguments.length < 4
      ) {
        const position = sourceFile.getLineAndCharacterOfPosition(node.getStart());
        offenders.push(`${path.relative(sourceRoot, file)}:${position.line + 1}`);
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
  }

  assert.deepEqual(offenders, []);
});

test("every literal translation lookup exists in English and Ukrainian", async () => {
  const { translations } = await loadI18nModule();
  const missing = [];

  for (const file of sourceFiles(sourceRoot)) {
    const { sourceFile } = parsedSource(file);
    const visit = (node) => {
      if (
        ts.isCallExpression(node)
        && ts.isIdentifier(node.expression)
        && node.expression.text === "t"
        && node.arguments.length > 0
        && ts.isStringLiteralLike(node.arguments[0])
      ) {
        const key = node.arguments[0].text;
        if (translations.en[key] === undefined || translations.uk[key] === undefined) {
          const position = sourceFile.getLineAndCharacterOfPosition(node.getStart());
          missing.push(`${path.relative(sourceRoot, file)}:${position.line + 1}:${key}`);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(sourceFile);
  }

  assert.deepEqual(missing, []);
});

test("Ukrainian is exposed by selectors, profile schema, and auxiliary copy maps", () => {
  const layout = fs.readFileSync(path.join(sourceRoot, "Layout.jsx"), "utf8");
  const languageSwitcher = fs.readFileSync(path.join(componentsDirectory, "LanguageSwitcher.jsx"), "utf8");
  const profile = fs.readFileSync(path.join(sourceRoot, "pages", "Profile.jsx"), "utf8");
  const community = fs.readFileSync(path.join(sourceRoot, "pages", "Community.jsx"), "utf8");
  const roulette = fs.readFileSync(path.join(componentsDirectory, "RouletteSpinner.jsx"), "utf8");
  const userSchema = JSON.parse(fs.readFileSync(path.resolve(sourceRoot, "..", "base44", "entities", "User.jsonc"), "utf8"));

  const expectedLanguages = ["en", "es", "ru", "uk"];
  const layoutLanguages = [...layout.matchAll(/code:\s*"(en|es|ru|uk)"/g)].map((match) => match[1]).sort();
  const switcherLanguages = [...languageSwitcher.matchAll(/code:\s*"(en|es|ru|uk)"/g)].map((match) => match[1]).sort();
  const profileLanguages = [...profile.matchAll(/<option value="(en|es|ru|uk)">/g)].map((match) => match[1]).sort();

  assert.deepEqual(layoutLanguages, expectedLanguages);
  assert.deepEqual(switcherLanguages, expectedLanguages);
  assert.deepEqual(profileLanguages, expectedLanguages);
  assert.match(languageSwitcher, /"Elegir idioma"/);
  assert.match(profile, /<option value="uk">УКРАЇНСЬКА<\/option>/);
  assert.match(community, /\n\s*uk:\s*\{[\s\S]*?eyebrow:\s*"\/\/ СПІЛЬНОТА"/);
  assert.match(roulette, /\n\s*uk:\s*\{[\s\S]*?gameStarting:\s*"\/\/ ГРА ПОЧИНАЄТЬСЯ"/);
  assert.deepEqual([...userSchema.properties.language.enum].sort(), expectedLanguages);
});
