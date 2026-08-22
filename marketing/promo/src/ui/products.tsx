import React from 'react';

/**
 * Flat product illustrations. Photography would mix a dozen lighting styles;
 * one drawn system keeps every catalogue tile on-brand.
 */

const Wrap: React.FC<{bg: string; children: React.ReactNode}> = ({bg, children}) => (
  <svg viewBox="0 0 100 100" width="100%" height="100%" style={{display: 'block', background: bg}}>
    {/* The drawings only occupy the middle half of the box; scale up so they
        still read as products at 40px cart-thumbnail size. */}
    <g transform="translate(50 50) scale(1.34) translate(-50 -50)">{children}</g>
  </svg>
);

export const ProdWater = () => (
  <Wrap bg="#EDF4F8">
    <rect x="43" y="16" width="14" height="8" rx="2" fill="#1E63C4" />
    <path d="M45 24h10v5l4 6v37a5 5 0 0 1-5 5H46a5 5 0 0 1-5-5V35l4-6v-5Z" fill="#BBD9EE" />
    <path d="M45 24h4v5l-4 6v42h-4a5 5 0 0 1 0 0V35l4-6v-5Z" fill="#DCEBF7" />
    <rect x="41" y="44" width="18" height="14" rx="2" fill="#1E63C4" opacity="0.9" />
    <rect x="44" y="48" width="12" height="2.4" rx="1.2" fill="#fff" opacity="0.85" />
    <rect x="44" y="52.5" width="8" height="2" rx="1" fill="#fff" opacity="0.6" />
  </Wrap>
);

export const ProdChips = () => (
  <Wrap bg="#EFF5EE">
    <path d="M30 22h40l-3 56a4 4 0 0 1-4 3.6H37a4 4 0 0 1-4-3.6L30 22Z" fill="#12703F" />
    <path d="M30 22h13l-2.5 59.6h-3.6a4 4 0 0 1-4-3.6L30 22Z" fill="#178A4D" />
    <path d="M28 18c3 2.5 6 0 9 2.5S43 18 46 20.5 52 18 55 20.5 61 18 64 20.5 70 18 72 20v4H28v-6Z" fill="#0D5730" />
    <ellipse cx="50" cy="48" rx="17" ry="12" fill="#F2C230" />
    <circle cx="43" cy="46" r="5.5" fill="#E8A81F" />
    <circle cx="55" cy="44" r="4.5" fill="#E8A81F" />
    <circle cx="50" cy="54" r="5" fill="#E8A81F" />
    <rect x="34" y="64" width="32" height="4" rx="2" fill="#fff" opacity="0.85" />
    <rect x="40" y="71" width="20" height="3" rx="1.5" fill="#fff" opacity="0.5" />
  </Wrap>
);

export const ProdChocolate = () => (
  <Wrap bg="#F2EFF6">
    <rect x="30" y="14" width="40" height="72" rx="4" fill="#4A2A73" />
    <rect x="30" y="14" width="13" height="72" rx="4" fill="#5D3690" />
    <rect x="30" y="40" width="40" height="26" fill="#EFE7F7" />
    <rect x="35" y="45" width="30" height="16" rx="2" fill="#6B4226" />
    <path d="M35 50h30M35 55.5h30M45 45v16M55 45v16" stroke="#8A5A34" strokeWidth="1.6" />
    <rect x="36" y="22" width="28" height="3.6" rx="1.8" fill="#fff" opacity="0.9" />
    <rect x="42" y="29" width="16" height="3" rx="1.5" fill="#fff" opacity="0.55" />
    <rect x="36" y="72" width="28" height="3" rx="1.5" fill="#fff" opacity="0.35" />
  </Wrap>
);

export const ProdJuice = () => (
  <Wrap bg="#FDF3E6">
    <path d="M33 24h34l-4 52a6 6 0 0 1-6 5.4H43a6 6 0 0 1-6-5.4L33 24Z" fill="#F79A1E" />
    <path d="M33 24h11l-3.5 57.4h-1a6 6 0 0 1-6-5.4L33 24Z" fill="#FBB44E" />
    <path d="M33 24h34l-.8 10H33.8L33 24Z" fill="#FFD08A" opacity="0.75" />
    <circle cx="70" cy="34" r="13" fill="#F8890F" />
    <circle cx="70" cy="34" r="10.5" fill="#FFC062" />
    <path d="M70 23.5v21M59.5 34h21M62.6 26.6l14.8 14.8M62.6 41.4l14.8-14.8" stroke="#F8890F" strokeWidth="1.7" />
  </Wrap>
);

export const ProdCoffee = () => (
  <Wrap bg="#F5F0EA">
    <path d="M35 26h30l-3.4 52a6 6 0 0 1-6 5.6H44.4a6 6 0 0 1-6-5.6L35 26Z" fill="#F4EFE8" />
    <path d="M35 26h10l-3 57.6h-1.6a6 6 0 0 1-6-5.6L35 26Z" fill="#FFFFFF" />
    <path d="M33.6 20h32.8a2 2 0 0 1 2 2.2l-.4 4H32l-.4-4a2 2 0 0 1 2-2.2Z" fill="#2A2A2A" />
    <path d="M37.6 44h24.8l-1.6 20H39.2l-1.6-20Z" fill="#B4794A" />
    <ellipse cx="50" cy="54" rx="6.6" ry="7.4" fill="#7A4A22" />
    <path d="M50 47.5c2.4 2.4 2.4 10.6 0 13" stroke="#B4794A" strokeWidth="1.6" strokeLinecap="round" />
  </Wrap>
);

export const ProdMilk = () => (
  <Wrap bg="#EEF3F9">
    <path d="M34 30h32v50a4 4 0 0 1-4 4H38a4 4 0 0 1-4-4V30Z" fill="#F4F8FC" />
    <path d="M34 30h10v54h-6a4 4 0 0 1-4-4V30Z" fill="#FFFFFF" />
    <path d="M34 30 50 15l16 15H34Z" fill="#DCE8F4" />
    <path d="M34 30 50 15v15H34Z" fill="#EAF1F9" />
    <rect x="34" y="44" width="32" height="22" fill="#1E63C4" />
    <rect x="39" y="50" width="22" height="4.4" rx="2.2" fill="#fff" />
    <rect x="43" y="58" width="14" height="3" rx="1.5" fill="#fff" opacity="0.7" />
    <path d="M34 40c6 3 10-3 16 0s10-3 16 0v4H34v-4Z" fill="#fff" opacity="0.55" />
  </Wrap>
);

export const ProdTissue = () => (
  <Wrap bg="#EAF5F2">
    <path d="M26 42h48v34a4 4 0 0 1-4 4H30a4 4 0 0 1-4-4V42Z" fill="#0F766E" />
    <path d="M26 42h12v38h-8a4 4 0 0 1-4-4V42Z" fill="#159187" />
    <path d="M26 42 34 32h32l8 10H26Z" fill="#0B5B55" />
    <path d="M43 42c0-6 5-9 7-15 2 6 7 9 7 15" fill="#F7FDFC" />
    <path d="M44 46h12" stroke="#0B5B55" strokeWidth="2" strokeLinecap="round" />
    <rect x="32" y="58" width="20" height="3.4" rx="1.7" fill="#fff" opacity="0.55" />
    <rect x="32" y="65" width="12" height="3" rx="1.5" fill="#fff" opacity="0.35" />
  </Wrap>
);

export const ProdDetergent = () => (
  <Wrap bg="#EAF2FA">
    <rect x="60" y="14" width="15" height="9" rx="2.5" fill="#1C4FA0" />
    <path d="M34 30h34a5 5 0 0 1 5 5v43a5 5 0 0 1-5 5H34a5 5 0 0 1-5-5V35a5 5 0 0 1 5-5Z" fill="#7FB6E8" />
    <path d="M34 30h10v53h-10a5 5 0 0 1-5-5V35a5 5 0 0 1 5-5Z" fill="#A6CDF2" />
    <path d="M60 23h9v7h-9z" fill="#2D66BC" />
    <rect x="33" y="44" width="36" height="24" rx="3" fill="#F7FAFE" />
    <rect x="38" y="50" width="26" height="4.4" rx="2.2" fill="#1C4FA0" />
    <rect x="42" y="58" width="18" height="3.4" rx="1.7" fill="#7FB6E8" />
  </Wrap>
);


export const ProdBread = () => (
  <Wrap bg="#FBF3E7">
    <path d="M22 46c0-9 6-16 14-16h28c8 0 14 7 14 16v24a6 6 0 0 1-6 6H28a6 6 0 0 1-6-6V46Z" fill="#D9A055" />
    <path d="M22 46c0-9 6-16 14-16h10c-8 0-14 7-14 16v30h-4a6 6 0 0 1-6-6V46Z" fill="#E8B771" />
    <path d="M28 33c2-5 7-7 11-4 3-4 9-4 12 0 3-4 9-4 12 0 4-3 9-1 11 4-4 3-9 1-11-2-3 4-9 4-12 0-3 4-9 4-12 0-2 3-7 5-11 2Z" fill="#F0CD97" />
    <path d="M34 56h32M34 64h24" stroke="#B8823B" strokeWidth="2.4" strokeLinecap="round" opacity="0.6" />
  </Wrap>
);

export const ProdRice = () => (
  <Wrap bg="#F4F1EA">
    <path d="M28 30h44v46a6 6 0 0 1-6 6H34a6 6 0 0 1-6-6V30Z" fill="#E4DCCB" />
    <path d="M28 30h12v52h-6a6 6 0 0 1-6-6V30Z" fill="#F0EADD" />
    <path d="M28 30c4-6 10-8 16-8h12c6 0 12 2 16 8H28Z" fill="#CFC4AC" />
    <rect x="33" y="44" width="34" height="22" rx="3" fill="#0F766E" />
    <rect x="38" y="50" width="24" height="4" rx="2" fill="#fff" />
    <rect x="43" y="58" width="14" height="3" rx="1.5" fill="#fff" opacity="0.7" />
  </Wrap>
);

export const ProdTea = () => (
  <Wrap bg="#F6EDEC">
    <rect x="30" y="26" width="40" height="52" rx="4" fill="#A5342C" />
    <rect x="30" y="26" width="12" height="52" rx="4" fill="#BF4239" />
    <path d="M36 40h28v20H36z" fill="#F7EEE9" />
    <path d="M50 44c-5 2-7 6-6 10 4 1 8-2 9-6 3 3 7 3 9 1-1-4-6-6-12-5Z" fill="#2F7D4F" />
    <rect x="36" y="66" width="28" height="3.4" rx="1.7" fill="#fff" opacity="0.85" />
    <rect x="42" y="30" width="16" height="3" rx="1.5" fill="#fff" opacity="0.55" />
  </Wrap>
);

export const ProdEggs = () => (
  <Wrap bg="#F3F0E8">
    <path d="M22 52c0-3 2-5 5-5h46c3 0 5 2 5 5v22a5 5 0 0 1-5 5H27a5 5 0 0 1-5-5V52Z" fill="#C9BFA8" />
    <path d="M22 52c0-3 2-5 5-5h10v32H27a5 5 0 0 1-5-5V52Z" fill="#DAD1BC" />
    <ellipse cx="35" cy="47" rx="10" ry="12" fill="#FBF6EC" />
    <ellipse cx="50" cy="45" rx="10" ry="12" fill="#F6EFE1" />
    <ellipse cx="65" cy="47" rx="10" ry="12" fill="#FBF6EC" />
    <path d="M28 66h44" stroke="#B0A48B" strokeWidth="2.2" strokeLinecap="round" />
  </Wrap>
);

export const PRODUCT_ART = {
  water: ProdWater,
  chips: ProdChips,
  chocolate: ProdChocolate,
  juice: ProdJuice,
  coffee: ProdCoffee,
  milk: ProdMilk,
  tissue: ProdTissue,
  detergent: ProdDetergent,
  bread: ProdBread,
  rice: ProdRice,
  tea: ProdTea,
  eggs: ProdEggs,
} as const;

export type ProductKey = keyof typeof PRODUCT_ART;

export const ProductArt: React.FC<{k: ProductKey}> = ({k}) => {
  const C = PRODUCT_ART[k];
  return <C />;
};
