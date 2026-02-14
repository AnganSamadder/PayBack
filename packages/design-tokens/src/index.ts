export const paybackTokens = {
  brand: {
    teal: "#0FB8C7",
    cyan: "#00CCE6",
    night: "#04141A",
    ink: "#0D1012",
    paper: "#F9FEFF"
  },
  semantic: {
    success: "#0BAA6E",
    warning: "#FFB13D",
    danger: "#E44646"
  }
} as const;

export type PaybackTokens = typeof paybackTokens;
