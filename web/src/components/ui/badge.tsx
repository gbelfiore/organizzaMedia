import * as React from "react"
import { cn } from "@/lib/utils"

export function Badge({ className, variant = "default", ...props }: React.HTMLAttributes<HTMLDivElement> & { variant?: "default" | "secondary" | "outline" | "ok" | "err" | "run" }) {
  return (
    <div
      className={cn(
        "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold",
        variant === "default" && "border-transparent bg-primary text-primary-foreground",
        variant === "secondary" && "border-transparent bg-secondary text-secondary-foreground",
        variant === "outline" && "text-foreground",
        variant === "ok" && "border-transparent bg-[#D9F56A] text-[#3D5A12]",
        variant === "err" && "border-transparent bg-[#F8C4B8] text-[#7A2E22]",
        variant === "run" && "border-transparent bg-[#FFF59A] text-[#5A4A10]",
        className
      )}
      {...props}
    />
  )
}
