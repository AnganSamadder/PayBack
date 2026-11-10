/** Server money policy. Historical rows retain their original precision and identities. */
export type MoneyRecord = {
  total_amount: number;
  currency_code?: string;
  splits: readonly { id: string; member_id: string; amount: number }[];
  subexpenses?: readonly { amount: number }[];
};
export type MoneyMode = "authoring" | "metadata" | "restore";
const MAX_AMOUNT = 1_000_000_000;
const ISO_CODES = new Set(
  "AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VES VND VUV WST XAF XCD XOF XPF YER ZAR ZMW ZWG".split(
    " "
  )
);
function finiteAmount(value: number, positive = false): void {
  if (!Number.isFinite(value) || value < 0 || (positive && value === 0) || value > MAX_AMOUNT) {
    throw new Error(
      "Invalid money: amounts must be finite, nonnegative and within the supported range"
    );
  }
}
function cents(value: number): number {
  const scaled = value * 100;
  const rounded = Math.round(scaled);
  if (
    !Number.isSafeInteger(rounded) ||
    Math.abs(scaled - rounded) > Number.EPSILON * Math.max(1, Math.abs(scaled)) * 2
  ) {
    throw new Error("Invalid money: new USD amounts require whole cents");
  }
  return rounded;
}
export function validateExpenseMoney(
  record: MoneyRecord,
  mode: MoneyMode,
  existing?: MoneyRecord
): void {
  if (mode === "metadata") {
    if (!existing) throw new Error("Existing expense required");
    if (record.currency_code !== undefined && record.currency_code !== existing.currency_code) {
      throw new Error("Expense currency is immutable");
    }
    const old = new Map(existing.splits.map((row) => [row.id, row]));
    if (
      record.total_amount !== existing.total_amount ||
      record.splits.length !== old.size ||
      record.splits.some((row) => {
        const before = old.get(row.id);
        return (
          !before ||
          before.amount !== row.amount ||
          before.member_id.toLowerCase() !== row.member_id.toLowerCase()
        );
      })
    )
      throw new Error("Historical financial amounts and split rows are immutable");
    if (
      !Number.isFinite(record.total_amount) ||
      record.splits.some((row) => !Number.isFinite(row.amount))
    ) {
      throw new Error("Invalid historical money");
    }
    for (const row of record.subexpenses ?? []) finiteAmount(row.amount);
    return;
  }
  finiteAmount(record.total_amount, mode === "authoring");
  if (mode === "authoring" && record.currency_code !== "USD") {
    throw new Error(
      "FINANCIAL_CONTRACT_UPGRADE_REQUIRED: new expenses require explicit USD currency"
    );
  }
  if (record.currency_code !== undefined && !ISO_CODES.has(record.currency_code))
    throw new Error("Unsupported currency code");
  if (
    !record.splits.length ||
    new Set(record.splits.map((row) => row.id)).size !== record.splits.length
  )
    throw new Error("Invalid split rows");
  for (const row of [...record.splits, ...(record.subexpenses ?? [])]) finiteAmount(row.amount);
  const sum = record.splits.reduce((total, row) => total + row.amount, 0);
  if (mode === "authoring") {
    if (
      record.splits.reduce((total, row) => total + cents(row.amount), 0) !==
      cents(record.total_amount)
    )
      throw new Error("Split amounts must equal expense total");
    for (const row of record.subexpenses ?? []) cents(row.amount);
  } else {
    // Only floating representation error, scaled by row count, is tolerated. No rounding/repair.
    const tolerance =
      Number.EPSILON *
      Math.max(1, record.total_amount, sum) *
      Math.max(4, record.splits.length * 2);
    if (Math.abs(sum - record.total_amount) > tolerance)
      throw new Error("Split amounts must equal expense total");
  }
}
