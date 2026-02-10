import { useState } from "react";
import { PrimaryCta } from "./components/PrimaryCta";
import { FooterLinks } from "./components/FooterLinks";

export default function Home() {
    const bg = "#1e2028";
    const shadowR = "8px 8px 16px rgba(10,12,18,0.6), -8px -8px 16px rgba(45,48,58,0.25)";
    const shadowI = "inset 4px 4px 8px rgba(10,12,18,0.5), inset -4px -4px 8px rgba(45,48,58,0.2)";
    const accent = "#10d5cf";
    const pink = "#f472b6";
    const muted = "#555a70";

    const [showToast, setShowToast] = useState(false);
    const [dismissing, setDismissing] = useState(false);
    const handleCtaClick = () => { setDismissing(false); setShowToast(true); };
    const handleDismiss = () => {
        setDismissing(true);
        setTimeout(() => { setShowToast(false); setDismissing(false); }, 300);
    };

    return (
        <div className="min-h-screen home-page" style={{ fontFamily: "'Karla', sans-serif", background: bg, color: "#c0c8e0" }}>
            <style>{`
              .home-page .primary-cta {
                transition: transform 0.2s ease, box-shadow 0.2s ease;
                cursor: pointer;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                background: #1e2028 !important;
                color: #10d5cf !important;
                border: none !important;
                border-radius: 1.4rem !important;
                box-shadow:
                  8px 8px 18px rgba(8,10,16,0.7),
                  -6px -6px 14px rgba(50,54,66,0.25),
                  inset 0 0 0 6px rgba(16,213,207,0.12),
                  inset 0 0 0 8px rgba(16,213,207,0.65) !important;
              }
              .home-page .primary-cta:hover {
                transform: translateY(-2px);
                box-shadow:
                  10px 10px 22px rgba(8,10,16,0.75),
                  -8px -8px 18px rgba(50,54,66,0.3),
                  0 0 20px rgba(16,213,207,0.1),
                  inset 0 0 0 6px rgba(16,213,207,0.12),
                  inset 0 0 0 8px rgba(16,213,207,0.3) !important;
              }
              .home-page .primary-cta:active {
                transform: translateY(1px);
                box-shadow:
                  inset 4px 4px 10px rgba(8,10,16,0.7),
                  inset -4px -4px 10px rgba(50,54,66,0.15),
                  inset 0 0 0 6px rgba(16,213,207,0.05),
                  inset 0 0 0 8px rgba(16,213,207,0.12) !important;
              }
              @keyframes pulse-dot {
                0%, 100% { opacity: 1; }
                50% { opacity: 0.4; }
              }
              @keyframes slide-down {
                from { transform: translate(-50%, -120%); opacity: 0; }
                to { transform: translate(-50%, 0); opacity: 1; }
              }
              @keyframes slide-up {
                from { transform: translate(-50%, 0); opacity: 1; }
                to { transform: translate(-50%, -120%); opacity: 0; }
              }
            `}</style>

            {showToast && (
                <div style={{
                    position: "fixed",
                    top: "1.5rem",
                    left: "50%",
                    transform: "translateX(-50%)",
                    zIndex: 1000,
                    background: bg,
                    boxShadow: `${shadowR}, inset 0 0 0 1px rgba(16,213,207,0.15)`,
                    borderRadius: "1.2rem",
                    padding: "1rem 1.4rem",
                    display: "flex",
                    alignItems: "center",
                    gap: "0.85rem",
                    maxWidth: "28rem",
                    width: "calc(100% - 2rem)",
                    animation: dismissing ? "slide-up 0.3s ease-in forwards" : "slide-down 0.35s ease-out",
                }}>
                    <span style={{
                        width: 10, height: 10, borderRadius: "50%", background: accent,
                        display: "inline-block", flexShrink: 0,
                        animation: "pulse-dot 2s ease-in-out infinite",
                    }} />
                    <p style={{ fontSize: "0.88rem", fontFamily: "'Outfit', sans-serif", margin: 0, flex: 1 }}>
                        <span style={{ color: accent, fontWeight: 600 }}>Coming soon on TestFlight!</span>
                        <br />
                        <span style={{ color: muted }}>Check back shortly, we're almost ready.</span>
                    </p>
                    <button
                        onClick={handleDismiss}
                        aria-label="Dismiss"
                        style={{
                            background: bg, border: "none", color: accent, cursor: "pointer",
                            fontSize: "0.85rem", lineHeight: 1, padding: 0, flexShrink: 0,
                            width: 32, height: 32, borderRadius: "50%",
                            display: "flex", alignItems: "center", justifyContent: "center",
                            boxShadow: "inset 3px 3px 8px rgba(8,10,16,0.6), inset -3px -3px 8px rgba(50,54,66,0.2)",
                            fontFamily: "'Outfit', sans-serif", fontWeight: 600,
                            transition: "box-shadow 0.15s ease, transform 0.15s ease",
                        }}
                        onMouseEnter={(e) => {
                            e.currentTarget.style.transform = "translateY(-1px)";
                            e.currentTarget.style.boxShadow = "4px 4px 10px rgba(8,10,16,0.6), -4px -4px 10px rgba(50,54,66,0.2)";
                        }}
                        onMouseLeave={(e) => {
                            e.currentTarget.style.transform = "translateY(0)";
                            e.currentTarget.style.boxShadow = "inset 3px 3px 8px rgba(8,10,16,0.6), inset -3px -3px 8px rgba(50,54,66,0.2)";
                        }}
                    >✕</button>
                </div>
            )}

            <header className="px-6 md:px-10 py-6 flex items-center justify-between">
                <span className="text-3xl font-bold" style={{ fontFamily: "'Outfit', sans-serif", color: accent, letterSpacing: "-0.03em" }}>PayBack</span>
                <PrimaryCta className="primary-cta" onClickFallback={handleCtaClick} style={{ color: bg, borderRadius: "1rem", fontFamily: "'Outfit', sans-serif", fontWeight: 600 }} />
            </header>

            <section className="px-6 md:px-10 py-16 md:py-24">
                <div className="grid md:grid-cols-2 gap-10 items-center max-w-6xl mx-auto">
                    <div>
                        <h1 className="text-4xl md:text-6xl font-bold leading-[0.95] mb-6" style={{ fontFamily: "'Outfit', sans-serif" }}>
                            Split bills,<br />
                            <span style={{ color: accent }}>keep friends.</span>
                        </h1>
                        <p className="text-base max-w-md mb-8" style={{ color: muted }}>
                            Stop chasing people for money. PayBack tracks every shared expense so you can focus on making memories, not spreadsheets.
                        </p>
                        <PrimaryCta className="primary-cta text-lg px-14 py-5" onClickFallback={handleCtaClick} style={{ borderRadius: "1rem", fontFamily: "'Outfit', sans-serif", fontWeight: 700, minHeight: "4rem", fontSize: "1.2rem", letterSpacing: "0.02em" }}>Get Now</PrimaryCta>
                    </div>
                    <div style={{ background: bg, borderRadius: "1.5rem", boxShadow: shadowR, padding: "1.5rem" }}>
                        <p className="text-xs font-bold uppercase tracking-wider mb-3" style={{ color: muted }}>Weekend trip</p>
                        <div className="space-y-3">
                            {[
                                { name: "Airbnb", amount: "$420.00", who: "Split 6 ways", dot: accent },
                                { name: "Groceries", amount: "$87.30", who: "Split 6 ways", dot: pink },
                                { name: "Kayak rental", amount: "$150.00", who: "Split 4 ways", dot: "#f59e0b" },
                                { name: "Dinner out", amount: "$212.60", who: "Split 6 ways", dot: "#a78bfa" },
                            ].map((item) => (
                                <div key={item.name} style={{ background: bg, borderRadius: "1rem", boxShadow: shadowI, padding: "0.75rem 1rem" }}>
                                    <div className="flex items-center justify-between">
                                        <div className="flex items-center gap-3">
                                            <span style={{ width: 10, height: 10, borderRadius: "50%", background: item.dot, display: "inline-block", flexShrink: 0 }} />
                                            <div>
                                                <span className="font-bold text-sm">{item.name}</span>
                                                <p className="text-xs" style={{ color: muted }}>{item.who}</p>
                                            </div>
                                        </div>
                                        <span className="font-bold text-sm" style={{ fontFamily: "'Outfit', sans-serif", color: accent }}>{item.amount}</span>
                                    </div>
                                </div>
                            ))}
                        </div>
                        <div className="mt-4 grid grid-cols-2 gap-3">
                            <div style={{ background: bg, borderRadius: "1rem", boxShadow: shadowR, padding: "0.75rem 1rem", textAlign: "center" }}>
                                <p className="text-xs" style={{ color: muted }}>Total</p>
                                <p className="text-lg font-bold" style={{ fontFamily: "'Outfit', sans-serif" }}>$869.90</p>
                            </div>
                            <div style={{ background: bg, borderRadius: "1rem", boxShadow: shadowR, padding: "0.75rem 1rem", textAlign: "center" }}>
                                <p className="text-xs" style={{ color: muted }}>You owe</p>
                                <p className="text-lg font-bold" style={{ fontFamily: "'Outfit', sans-serif", color: pink }}>$144.98</p>
                            </div>
                        </div>
                    </div>
                </div>
            </section>

            <section className="px-6 md:px-10 py-16" aria-labelledby="features-heading">
                <h2 id="features-heading" className="text-2xl font-bold text-center mb-12" style={{ fontFamily: "'Outfit', sans-serif" }}>How it works</h2>
                <div className="grid md:grid-cols-2 gap-8 max-w-4xl mx-auto">
                    {[
                        {
                            icon: (
                                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke={accent} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                                    <path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z" />
                                    <circle cx="12" cy="13" r="4" />
                                </svg>
                            ),
                            title: "Snap & split",
                            desc: "Take a photo of the bill. PayBack reads it instantly — 14 languages, any format.",
                        },
                        {
                            icon: (
                                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke={accent} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                                    <polyline points="23 4 23 10 17 10" />
                                    <polyline points="1 20 1 14 7 14" />
                                    <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15" />
                                </svg>
                            ),
                            title: "Real-time sync",
                            desc: "Everyone sees updates the moment they happen. No refreshing, no waiting.",
                        },
                        {
                            icon: (
                                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke={accent} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                                    <path d="M21.21 15.89A10 10 0 1 1 8 2.83" />
                                    <path d="M22 12A10 10 0 0 0 12 2v10z" />
                                </svg>
                            ),
                            title: "Group insights",
                            desc: "See spending breakdowns by category, person, and month. Know where every dollar goes.",
                        },
                        {
                            icon: (
                                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke={accent} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                                    <path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
                                    <circle cx="8.5" cy="7" r="4" />
                                    <line x1="20" y1="8" x2="20" y2="14" />
                                    <line x1="23" y1="11" x2="17" y2="11" />
                                </svg>
                            ),
                            title: "No app? No problem",
                            desc: "Split with anyone — friends, roommates, your mom. They don't need an account. Just add them and go.",
                        },
                    ].map((f) => (
                        <div key={f.title} style={{ background: bg, borderRadius: "1.5rem", boxShadow: shadowR, padding: "1.5rem", textAlign: "center" }}>
                            <div style={{ background: bg, borderRadius: "50%", boxShadow: shadowI, width: 52, height: 52, display: "flex", alignItems: "center", justifyContent: "center", margin: "0 auto 1rem" }}>{f.icon}</div>
                            <h3 className="text-lg font-bold mb-2" style={{ fontFamily: "'Outfit', sans-serif" }}>{f.title}</h3>
                            <p className="text-sm leading-relaxed" style={{ color: muted }}>{f.desc}</p>
                        </div>
                    ))}
                </div>
            </section>

            <section className="px-6 py-14 text-center">
                <div style={{ background: bg, borderRadius: "1.5rem", boxShadow: shadowR, padding: "2rem 2.5rem", maxWidth: "36rem", margin: "0 auto" }}>
                    <p className="text-2xl md:text-3xl font-bold mb-2" style={{ fontFamily: "'Outfit', sans-serif" }}>
                        Free forever <span style={{ color: accent }}>•</span> No ads <span style={{ color: accent }}>•</span> No catch
                    </p>
                    <p className="text-sm" style={{ color: muted }}>
                        Just a clean app that does one thing really, really well.
                    </p>
                </div>
            </section>

            <section className="px-6 py-24 text-center">
                <h2 className="text-3xl md:text-5xl font-bold mb-6" style={{ fontFamily: "'Outfit', sans-serif" }}>
                    Ready to stop <span style={{ color: accent }}>guessing?</span>
                </h2>
                <PrimaryCta className="primary-cta text-lg px-12 py-5" onClickFallback={handleCtaClick} style={{ color: bg, borderRadius: "1rem", fontFamily: "'Outfit', sans-serif", fontWeight: 700, minHeight: "4rem", fontSize: "1.15rem" }}>Get Now</PrimaryCta>
            </section>

            <FooterLinks className="footer-links justify-center px-6 py-8" style={{ color: muted }} />
        </div >
    );
}
