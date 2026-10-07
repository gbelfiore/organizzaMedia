type Props = {
  size?: number
  className?: string
}

export function CameraLogo({ size = 40, className }: Props) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      aria-hidden
    >
      <rect x="6" y="16" width="52" height="38" rx="12" fill="#D9F56A" />
      <rect x="6" y="16" width="52" height="38" rx="12" stroke="#3D5A12" strokeWidth="2.5" />
      <path d="M22 16l3.2-7h13.6L42 16" fill="#B8E84A" stroke="#3D5A12" strokeWidth="2.5" strokeLinejoin="round" />
      <circle cx="32" cy="36" r="11" fill="#F4FFE0" stroke="#3D5A12" strokeWidth="2.5" />
      <circle cx="32" cy="36" r="6.5" fill="#7CDE2A" />
      <circle cx="29.5" cy="33.5" r="2.2" fill="white" />
      <circle cx="48.5" cy="25.5" r="3.2" fill="#FFF59A" stroke="#3D5A12" strokeWidth="2" />
      <path d="M20 48c2.4 3 6.2 4.6 12 4.6S41.6 51 44 48" stroke="#3D5A12" strokeWidth="2" strokeLinecap="round" />
    </svg>
  )
}
