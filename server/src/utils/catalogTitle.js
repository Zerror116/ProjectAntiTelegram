function normalizeCatalogTitle(rawTitle) {
  const title = String(rawTitle || "").trim();
  if (!title) return "";

  const chars = Array.from(title);
  const firstLetterIndex = chars.findIndex((char) => /\p{L}/u.test(char));
  if (firstLetterIndex < 0) return title;

  chars[firstLetterIndex] = chars[firstLetterIndex].toLocaleUpperCase("ru-RU");
  return chars.join("");
}

module.exports = {
  normalizeCatalogTitle,
};
