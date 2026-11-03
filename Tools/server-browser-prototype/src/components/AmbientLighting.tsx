/**
 * Ambient background lighting for San Andreas Online:
 * Soft blurred warm amber and deep indigo/purple glows that create
 * the atmospheric lighting of San Andreas Online.
 */
export function AmbientLighting() {
  return (
    <div className="ambient-lighting" aria-hidden="true">
      <div className="ambient-glow ambient-glow--amber-tr" />
      <div className="ambient-glow ambient-glow--purple-tr" />
      <div className="ambient-glow ambient-glow--amber-bl" />
      <div className="ambient-glow ambient-glow--purple-bl" />
      <div className="ambient-glow ambient-glow--neutral" />
    </div>
  )
}
