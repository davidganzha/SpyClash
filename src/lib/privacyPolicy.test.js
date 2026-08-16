import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const policySource = await readFile(
  new URL("../pages/PrivacyPolicy.jsx", import.meta.url),
  "utf8",
);

test("privacy policy has complete English, Russian, Ukrainian, and Spanish surfaces", () => {
  for (const marker of [
    "PRIVACY POLICY",
    "ПОЛИТИКА КОНФИДЕНЦИАЛЬНОСТИ",
    "ПОЛІТИКА КОНФІДЕНЦІЙНОСТІ",
    "POLÍTICA DE PRIVACIDAD",
    "RU_PRIVACY_SECTIONS",
    "UK_PRIVACY_SECTIONS",
    "ES_PRIVACY_SECTIONS",
  ]) {
    assert.match(policySource, new RegExp(marker));
  }

  assert.match(policySource, /PRIVACY_SECTIONS_BY_LANGUAGE\[lang\]/);

  for (const localeArray of [
    "RU_PRIVACY_SECTIONS",
    "UK_PRIVACY_SECTIONS",
    "ES_PRIVACY_SECTIONS",
  ]) {
    const localizedSections = policySource.match(
      new RegExp(`const ${localeArray} = \\[([\\s\\S]*?)\\n\\];`),
    )?.[1];
    assert.ok(localizedSections, `${localeArray} must be present`);
    assert.equal(
      [...localizedSections.matchAll(/title:/g)].length,
      8,
      `${localeArray} must contain all eight sections`,
    );
  }
});

test("privacy policy accurately describes the active cache-miss AI path", () => {
  for (const marker of [
    "when no suitable cached result is available",
    "если подходящего результата в кэше нет",
    "коли немає придатного кешованого результату",
    "cuando no hay un resultado adecuado en caché",
    "Base44 InvokeLLM",
    "When you use optional AI word-pack generation",
    "Separate function logs record allow-listed operational fields",
    "Cuando utilizas la generación opcional de paquetes de palabras mediante IA",
    "Los registros separados de funciones guardan campos operativos incluidos en una lista permitida",
    "Когда вы используете необязательную генерацию наборов слов с помощью ИИ",
    "Отдельные журналы функций записывают разрешенные операционные поля",
    "Коли ви використовуєте необов’язкову генерацію наборів слів за допомогою ШІ",
    "Окремі журнали функцій записують дозволені операційні поля",
    "same or equivalent protection",
    "такую же или равнозначную защиту",
    "такий самий або рівнозначний захист",
    "la misma protección o una equivalente",
  ]) {
    assert.ok(policySource.toLocaleLowerCase().includes(marker.toLocaleLowerCase()));
  }

  assert.doesNotMatch(policySource, /Responses API/i);
  assert.doesNotMatch(policySource, /language are sent/i);
  assert.doesNotMatch(policySource, /configure and oversee/i);
  assert.doesNotMatch(policySource, /No direct OpenAI endpoint is currently configured/i);
  assert.doesNotMatch(policySource, /cache does not retain[^\n]+provider-attempt results/i);
});

test("privacy policy identifies its August 2026 revision in all locales", () => {
  for (const marker of [
    "Last updated: August 2026",
    "Последнее обновление: август 2026 г.",
    "Останнє оновлення: серпень 2026 р.",
    "Última actualización: agosto de 2026",
  ]) {
    assert.ok(policySource.includes(marker));
  }
});
