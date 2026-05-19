// SVG asset library — all 8 illustrated assets for the presentation
// Each is a self-contained SVG string suitable for innerHTML insertion.
// Uses currentColor + CSS vars so light/dark modes both work.

const SVGs = {};

// A: GitOps three-step flow — Git → Flux → Cluster
SVGs.gitops = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 160" role="img" aria-label="GitOps flow: code repository to Flux to cluster">
  <style>
    .box { fill: none; stroke: currentColor; stroke-width: 2; rx: 8; }
    .label { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; font-size: 13px; fill: currentColor; text-anchor: middle; }
    .sublabel { font-size: 11px; opacity: 0.6; }
    .arrow { stroke: var(--accent,#3b82f6); stroke-width: 2; fill: none; marker-end: url(#ah); }
    .ret { stroke: var(--accent,#3b82f6); stroke-width: 1.5; fill: none; marker-end: url(#ah); stroke-dasharray:4,3; opacity:0.7; }
    .accent-fill { fill: var(--accent,#3b82f6); }
  </style>
  <defs>
    <marker id="ah" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" class="accent-fill"/>
    </marker>
  </defs>
  <!-- Box 1: Git Repository -->
  <rect x="20" y="50" width="130" height="60" rx="8" class="box"/>
  <text x="85" y="76" class="label" font-weight="600">Git repository</text>
  <text x="85" y="94" class="label sublabel">Every setting is a file</text>
  <text x="85" y="109" class="label sublabel">Infinite undo history</text>
  <!-- Arrow 1→2 -->
  <line x1="152" y1="80" x2="198" y2="80" class="arrow"/>
  <!-- Box 2: Flux -->
  <rect x="200" y="50" width="130" height="60" rx="8" class="box"/>
  <text x="265" y="76" class="label" font-weight="600">Flux</text>
  <text x="265" y="94" class="label sublabel">Reads repository</text>
  <text x="265" y="109" class="label sublabel">every hour</text>
  <!-- Arrow 2→3 -->
  <line x1="332" y1="80" x2="378" y2="80" class="arrow"/>
  <!-- Box 3: Cluster -->
  <rect x="380" y="50" width="130" height="60" rx="8" class="box"/>
  <text x="445" y="76" class="label" font-weight="600">Cluster</text>
  <text x="445" y="94" class="label sublabel">Always matches</text>
  <text x="445" y="109" class="label sublabel">the code</text>
  <!-- Return arrow (curved, dashed) -->
  <path d="M 445 112 Q 445 145 265 145 Q 85 145 85 112" class="ret"/>
  <text x="265" y="158" class="label sublabel" style="font-style:italic">Manual change? Overwritten on next sync.</text>
</svg>`;

// B: Six-step change lifecycle flow
SVGs.lifecycle = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 680 120" role="img" aria-label="Change lifecycle: Request, Plan, QA Check, Execute, Evidence, Close">
  <style>
    .step { fill: none; stroke: currentColor; stroke-width: 2; }
    .step-fill { fill: color-mix(in srgb, var(--accent,#3b82f6) 12%, transparent); stroke: var(--accent,#3b82f6); stroke-width: 2; }
    .lbl { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; font-size: 12px; fill: currentColor; text-anchor: middle; font-weight:600; }
    .num { font-size: 10px; fill: var(--accent,#3b82f6); text-anchor: middle; }
    .arr { stroke: var(--accent,#3b82f6); stroke-width: 2; fill: none; marker-end: url(#bh); }
    .af { fill: var(--accent,#3b82f6); }
  </style>
  <defs>
    <marker id="bh" markerWidth="7" markerHeight="7" refX="5" refY="3" orient="auto">
      <path d="M0,0 L0,6 L7,3 z" class="af"/>
    </marker>
  </defs>
  ${[
    {x:10, n:"1", t:"Request"},
    {x:123, n:"2", t:"Plan"},
    {x:236, n:"3", t:"QA Check"},
    {x:349, n:"4", t:"Execute"},
    {x:462, n:"5", t:"Evidence"},
    {x:575, n:"6", t:"Close"},
  ].map(({x,n,t}) => `
    <rect x="${x}" y="20" width="95" height="48" rx="6" class="${n==="3"||n==="5"?"step-fill":"step"}"/>
    <text x="${x+47}" y="39" class="num">STEP ${n}</text>
    <text x="${x+47}" y="57" class="lbl">${t}</text>
  `).join("")}
  ${[113,226,339,452,565].map(x => `<line x1="${x}" y1="44" x2="${x+10}" y2="44" class="arr"/>`).join("")}
</svg>`;

// C: Risk dial — Low / Medium / High
SVGs.riskdial = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 220" role="img" aria-label="Risk dial showing low medium high tiers">
  <style>
    body { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
    text { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; fill: currentColor; }
    .band-low { fill: #22c55e; opacity: 0.85; }
    .band-med { fill: #f59e0b; opacity: 0.85; }
    .band-hi  { fill: #ef4444; opacity: 0.85; }
    .band-bg  { fill: none; stroke: currentColor; stroke-width: 1.5; opacity: 0.2; }
    .needle   { stroke: currentColor; stroke-width: 3; stroke-linecap: round; }
    .label    { font-size: 13px; font-weight: 700; text-anchor: middle; fill: #fff; }
    .desc     { font-size: 11px; fill: currentColor; }
    .center   { fill: currentColor; }
  </style>
  <!-- Dial bands (semicircle at cx=250 cy=160 r=100) -->
  <!-- Low: -180 to -120 deg (left third) -->
  <path d="M 150,160 A 100,100 0 0,1 200,73.4 L 220,108 A 60,60 0 0,0 190,160 Z" class="band-low"/>
  <!-- Medium: -120 to -60 deg (middle) -->
  <path d="M 200,73.4 A 100,100 0 0,1 300,73.4 L 280,108 A 60,60 0 0,0 220,108 Z" class="band-med"/>
  <!-- High: -60 to 0 deg (right third) -->
  <path d="M 300,73.4 A 100,100 0 0,1 350,160 L 310,160 A 60,60 0 0,0 280,108 Z" class="band-hi"/>
  <!-- Outer ring -->
  <path d="M 150,160 A 100,100 0 0,1 350,160" fill="none" stroke="currentColor" stroke-width="2" opacity="0.3"/>
  <!-- Needle pointing medium (straight up ≈ medium) -->
  <line x1="250" y1="160" x2="250" y2="70" class="needle"/>
  <circle cx="250" cy="160" r="8" class="center"/>
  <!-- Labels -->
  <text x="172" y="148" class="label" fill="#fff" font-size="12">LOW</text>
  <text x="250" y="92" class="label" fill="#fff" font-size="12">MED</text>
  <text x="328" y="148" class="label" fill="#fff" font-size="12">HIGH</text>
  <!-- Description rows -->
  <text x="20" y="190" class="desc">● LOW — auto-execute, just log it (image bump, comment edit)</text>
  <text x="20" y="207" class="desc">● MED — Themis QA must pass (new automation, network route)</text>
  <text x="20" y="224" class="desc" style="fill:#ef4444">● HIGH — Sander approval + QA (auth, firewall, storage, OS)</text>
</svg>`;

// D: Network segmentation diagram
SVGs.network = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 200" role="img" aria-label="Network segmentation: server VLAN, client VLAN, IoT VLAN with firewall">
  <style>
    text { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; fill: currentColor; font-size: 12px; text-anchor: middle; }
    .lane { fill: none; stroke-width: 2; rx: 8; }
    .srv  { stroke: var(--accent,#3b82f6); }
    .cli  { stroke: #22c55e; }
    .iot  { stroke: #f59e0b; }
    .srv-bg { fill: color-mix(in srgb, var(--accent,#3b82f6) 8%, transparent); }
    .cli-bg { fill: color-mix(in srgb, #22c55e 8%, transparent); }
    .iot-bg { fill: color-mix(in srgb, #f59e0b 8%, transparent); }
    .fw   { stroke: #ef4444; stroke-width: 2; fill: none; }
    .arr  { stroke: currentColor; stroke-width: 1.5; opacity: 0.5; marker-end: url(#dh); fill: none; }
    .cloud{ stroke: currentColor; stroke-width: 2; fill: none; opacity: 0.5; stroke-dasharray: 5,3; }
    .df { fill: currentColor; opacity: 0.5; }
  </style>
  <defs>
    <marker id="dh" markerWidth="6" markerHeight="6" refX="4" refY="3" orient="auto">
      <path d="M0,0 L0,6 L6,3 z" class="df"/>
    </marker>
  </defs>
  <!-- Internet cloud -->
  <ellipse cx="280" cy="20" rx="60" ry="16" class="cloud"/>
  <text x="280" y="24" font-size="11" opacity="0.6">Internet / Cloudflare</text>
  <!-- Down to firewall -->
  <line x1="280" y1="37" x2="280" y2="55" class="arr"/>
  <!-- Firewall -->
  <rect x="245" y="55" width="70" height="30" rx="5" class="fw"/>
  <text x="280" y="74" font-size="11" style="fill:#ef4444" font-weight="600">Firewall</text>
  <!-- Three lanes -->
  <!-- Server VLAN -->
  <rect x="20" y="105" width="150" height="80" rx="8" class="lane srv srv-bg"/>
  <text x="95" y="122" font-weight="700" style="fill:var(--accent,#3b82f6)">SERVER-VLAN</text>
  <text x="95" y="140" font-size="10">3× CP node</text>
  <text x="95" y="156" font-size="10">3× Worker node</text>
  <text x="95" y="172" font-size="10">NAS • UDM</text>
  <!-- Client VLAN -->
  <rect x="200" y="105" width="150" height="80" rx="8" class="lane cli cli-bg"/>
  <text x="275" y="122" font-weight="700" style="fill:#22c55e">CLIENT-VLAN</text>
  <text x="275" y="140" font-size="10">Laptops</text>
  <text x="275" y="156" font-size="10">Phones</text>
  <text x="275" y="172" font-size="10">Tablets</text>
  <!-- IoT VLAN -->
  <rect x="380" y="105" width="160" height="80" rx="8" class="lane iot iot-bg"/>
  <text x="460" y="122" font-weight="700" style="fill:#f59e0b">IOT-VLAN</text>
  <text x="460" y="140" font-size="10">Sensors • Cameras</text>
  <text x="460" y="156" font-size="10">Smart plugs</text>
  <text x="460" y="172" font-size="10">EV charger</text>
  <!-- Lines from firewall to lanes -->
  <line x1="265" y1="85" x2="95" y2="105" class="arr"/>
  <line x1="280" y1="85" x2="275" y2="105" class="arr"/>
  <line x1="295" y1="85" x2="460" y2="105" class="arr"/>
  <!-- BGP label -->
  <text x="195" y="99" font-size="9" style="fill:var(--accent,#3b82f6)">BGP routing</text>
</svg>`;

// E: Team deity cards are inline HTML not SVG — handled in the HTML directly

// F: House-with-dots infographic
SVGs.house = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 280" role="img" aria-label="House with smart device locations marked">
  <style>
    text { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; fill: currentColor; font-size: 10px; text-anchor: middle; }
    .wall { fill: none; stroke: currentColor; stroke-width: 2; }
    .roof { fill: none; stroke: currentColor; stroke-width: 2; stroke-linejoin: round; }
    .dot  { fill: var(--accent,#3b82f6); }
    .dotw { fill: #f59e0b; }
    .dotg { fill: #22c55e; }
    .dotr { fill: #ef4444; }
    .line { stroke: currentColor; stroke-width: 1; opacity: 0.25; stroke-dasharray: 3,3; }
  </style>
  <!-- House outline -->
  <polygon points="60,140 180,40 300,140" class="roof"/>
  <rect x="75" y="140" width="210" height="120" class="wall"/>
  <!-- Door -->
  <rect x="155" y="200" width="50" height="60" class="wall"/>
  <!-- Windows -->
  <rect x="95" y="158" width="40" height="35" class="wall"/>
  <rect x="230" y="158" width="40" height="35" class="wall"/>
  <!-- Garage -->
  <rect x="75" y="240" width="70" height="20" class="wall"/>

  <!-- Dots with labels -->
  <!-- Kitchen tablet -->
  <circle cx="225" cy="168" r="7" class="dot"/>
  <text x="270" y="162">Kitchen</text>
  <text x="270" y="174">tablet</text>

  <!-- Doorbell -->
  <circle cx="155" cy="200" r="6" class="dotw"/>
  <text x="138" y="193">Doorbell</text>

  <!-- Thermostat -->
  <circle cx="110" cy="165" r="6" class="dotg"/>
  <text x="95" y="155">Thermostat</text>

  <!-- EV charger -->
  <circle cx="110" cy="248" r="6" class="dotw"/>
  <text x="110" y="270">EV charger</text>

  <!-- Router/rack -->
  <circle cx="180" cy="100" r="7" class="dot"/>
  <text x="215" y="98">Home rack</text>
  <text x="215" y="110">(cluster)</text>

  <!-- Solar -->
  <circle cx="240" cy="75" r="7" class="dotw"/>
  <text x="270" y="72">Solar</text>
  <text x="270" y="84">inverter</text>

  <!-- Garden sensors -->
  <circle cx="95" cy="248" r="5" class="dotg"/>
  <circle cx="80" cy="248" r="5" class="dotg"/>
  <circle cx="65" cy="248" r="5" class="dotg"/>
  <text x="75" y="268">Soil sensors</text>

  <!-- Motion sensor -->
  <circle cx="300" cy="165" r="5" class="dotr"/>
  <text x="318" y="161">Motion</text>
  <text x="318" y="173">sensor</text>
</svg>`;

// G: Hardware stand-in diagram — 3 CP nodes, 3 workers, switch, UDM, NAS
SVGs.hardware = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 220" role="img" aria-label="Hardware diagram: 3 control plane nodes, 3 worker nodes, switch, UDM Pro, Synology NAS">
  <style>
    text { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; fill: currentColor; font-size: 11px; text-anchor: middle; }
    .box  { fill: none; stroke: currentColor; stroke-width: 2; rx: 4; }
    .cp   { stroke: var(--accent,#3b82f6); }
    .wk   { stroke: #22c55e; }
    .net  { stroke: #f59e0b; }
    .nas  { stroke: #8b5cf6; }
    .cp-bg{ fill: color-mix(in srgb, var(--accent,#3b82f6) 8%, transparent); }
    .wk-bg{ fill: color-mix(in srgb, #22c55e 8%, transparent); }
    .net-bg{ fill: color-mix(in srgb, #f59e0b 8%, transparent); }
    .nas-bg{ fill: color-mix(in srgb, #8b5cf6 8%, transparent); }
    .wire { stroke: currentColor; stroke-width: 1.5; opacity: 0.4; }
    .section-lbl { font-size: 10px; opacity: 0.5; letter-spacing: 0.08em; text-transform: uppercase; }
  </style>
  <!-- Switch (central) -->
  <rect x="235" y="95" width="130" height="30" rx="4" class="box net net-bg"/>
  <text x="300" y="114" font-weight="600" style="fill:#f59e0b">Network switch</text>

  <!-- UDM Pro -->
  <rect x="235" y="50" width="130" height="30" rx="4" class="box net net-bg"/>
  <text x="300" y="69" font-weight="600" style="fill:#f59e0b">UDM Pro Max</text>
  <line x1="300" y1="80" x2="300" y2="95" class="wire"/>

  <!-- CP nodes left -->
  <text x="90" y="32" class="section-lbl">Control Plane</text>
  ${[0,1,2].map(i => `
    <rect x="15" y="${45+i*48}" width="150" height="38" rx="4" class="box cp cp-bg"/>
    <text x="90" y="${59+i*48}" font-weight="600" style="fill:var(--accent,#3b82f6)">CP${i+1} — Beelink EQ14</text>
    <text x="90" y="${73+i*48}" style="opacity:0.6">N150 · 16 GB · 500 GB</text>
    <line x1="166" y1="${64+i*48}" x2="235" y2="110" class="wire"/>
  `).join("")}

  <!-- Worker nodes right -->
  <text x="480" y="32" class="section-lbl">Workers</text>
  ${[0,1,2].map(i => `
    <rect x="400" y="${45+i*48}" width="155" height="38" rx="4" class="box wk wk-bg"/>
    <text x="478" y="${59+i*48}" font-weight="600" style="fill:#22c55e">W${i+1} — Intel NUC 11</text>
    <text x="478" y="${73+i*48}" style="opacity:0.6">i5 · NVMe + 1 TB SSD</text>
    <line x1="400" y1="${64+i*48}" x2="365" y2="110" class="wire"/>
  `).join("")}

  <!-- NAS -->
  <rect x="235" y="150" width="130" height="38" rx="4" class="box nas nas-bg"/>
  <text x="300" y="165" font-weight="600" style="fill:#8b5cf6">Synology NAS</text>
  <text x="300" y="179" style="opacity:0.6">Large media storage</text>
  <line x1="300" y1="150" x2="300" y2="125" class="wire"/>
</svg>`;

// H: Three-source charge diagram — Solar + Grid price → evcc → Car
SVGs.charger = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 160" role="img" aria-label="Three-source EV charge diagram: solar inverter and grid price feed into evcc which controls car charging">
  <style>
    text { font-family: -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; fill: currentColor; font-size: 12px; text-anchor: middle; }
    .box  { fill: none; stroke: currentColor; stroke-width: 2; rx: 8; }
    .solar{ stroke: #f59e0b; }
    .grid { stroke: #6366f1; }
    .evcc { stroke: var(--accent,#3b82f6); }
    .car  { stroke: #22c55e; }
    .solar-bg { fill: color-mix(in srgb, #f59e0b 10%, transparent); }
    .grid-bg  { fill: color-mix(in srgb, #6366f1 10%, transparent); }
    .evcc-bg  { fill: color-mix(in srgb, var(--accent,#3b82f6) 10%, transparent); }
    .car-bg   { fill: color-mix(in srgb, #22c55e 10%, transparent); }
    .arr  { stroke: var(--accent,#3b82f6); stroke-width: 2; fill: none; marker-end: url(#hh); }
    .hf   { fill: var(--accent,#3b82f6); }
    .anim-arrow { stroke: #f59e0b; stroke-width: 2.5; fill: none; marker-end: url(#hh2); }
    .hf2  { fill: #f59e0b; }
  </style>
  <defs>
    <marker id="hh" markerWidth="7" markerHeight="7" refX="5" refY="3" orient="auto">
      <path d="M0,0 L0,6 L7,3 z" class="hf"/>
    </marker>
    <marker id="hh2" markerWidth="7" markerHeight="7" refX="5" refY="3" orient="auto">
      <path d="M0,0 L0,6 L7,3 z" class="hf2"/>
    </marker>
  </defs>
  <!-- Solar inverter -->
  <rect x="10" y="20" width="130" height="50" rx="8" class="box solar solar-bg"/>
  <text x="75" y="42" font-weight="700" style="fill:#f59e0b">☀ Solar inverter</text>
  <text x="75" y="60" font-size="10" style="opacity:0.7">Live surplus output</text>
  <!-- Grid price -->
  <rect x="10" y="90" width="130" height="50" rx="8" class="box grid grid-bg"/>
  <text x="75" y="112" font-weight="700" style="fill:#6366f1">⚡ Grid tariff</text>
  <text x="75" y="130" font-size="10" style="opacity:0.7">Live Zonneplan price</text>
  <!-- Arrows to evcc -->
  <line x1="142" y1="45" x2="210" y2="75" class="arr"/>
  <line x1="142" y1="115" x2="210" y2="85" class="arr"/>
  <!-- evcc -->
  <rect x="210" y="55" width="110" height="50" rx="8" class="box evcc evcc-bg"/>
  <text x="265" y="77" font-weight="700" style="fill:var(--accent,#3b82f6)">evcc</text>
  <text x="265" y="95" font-size="10" style="opacity:0.7">Charge controller</text>
  <!-- Arrow evcc → car -->
  <line x1="322" y1="80" x2="380" y2="80" class="arr"/>
  <!-- Car -->
  <rect x="382" y="55" width="130" height="50" rx="8" class="box car car-bg"/>
  <text x="447" y="77" font-weight="700" style="fill:#22c55e">🔋 Tesla</text>
  <text x="447" y="95" font-size="10" style="opacity:0.7">Charges optimally</text>
</svg>`;

export default SVGs;
