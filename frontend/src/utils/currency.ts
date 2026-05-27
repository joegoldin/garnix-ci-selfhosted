export const formatPrice = ({
  unit_amount,
  currency,
}: {
  unit_amount: number;
  currency: string;
}): string => `${(unit_amount / 100).toFixed(2)} ${currency.toUpperCase()}`;

export const formatTaxType = (taxType: string | null): string => {
  if (taxType == null) {
    return "Tax";
  }
  const snippets = taxType.split("_");
  if (snippets.length === 1) return taxType.toUpperCase();
  return snippets
    .map((snippet) => snippet.charAt(0).toUpperCase() + snippet.slice(1))
    .join(" ");
};
