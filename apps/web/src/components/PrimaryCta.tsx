import type { CSSProperties } from "react";
import { useLocation } from "@tanstack/react-router";
import { hasTestflightUrl, testflightUrl, warnMissingTestflightUrl } from "../lib/env";
import { trackCtaClick } from "../lib/analytics";

type PrimaryCtaProps = {
  className?: string;
  style?: CSSProperties;
  children?: React.ReactNode;
  onClickFallback?: () => void;
};

export function PrimaryCta({ className, style, children, onClickFallback }: PrimaryCtaProps) {
  const location = useLocation();

  if (!hasTestflightUrl) {
    warnMissingTestflightUrl();
  }

  const handleClick = (e: React.MouseEvent) => {
    trackCtaClick(location.pathname);
    if (!hasTestflightUrl && onClickFallback) {
      e.preventDefault();
      onClickFallback();
    }
  };

  return (
    <a
      className={className}
      style={style}
      href={hasTestflightUrl ? testflightUrl : "#"}
      onClick={handleClick}
      role="button"
      target={hasTestflightUrl ? "_blank" : undefined}
      rel={hasTestflightUrl ? "noreferrer" : undefined}
    >
      {children ?? "Try PayBack on iPhone"}
    </a>
  );
}
