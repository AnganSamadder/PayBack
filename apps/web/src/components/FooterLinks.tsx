import type { CSSProperties } from "react";

export function FooterLinks({ className, style }: { className?: string; style?: CSSProperties }) {
  return (
    <footer className={className} style={style}>
      <a href="https://github.com/AnganSamadder/PayBack" target="_blank" rel="noreferrer">
        GitHub
      </a>
      <a href="mailto:hello@payback.app">Contact</a>
    </footer>
  );
}
