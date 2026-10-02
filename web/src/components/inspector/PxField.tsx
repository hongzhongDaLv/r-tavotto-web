import type { ComponentProps, ReactNode } from 'react'
import { useDocumentStore } from '@/store/documentStore'
import type { UiMessage } from '@/i18n'
import { editorPxToMm, mmToEditorPx } from '@/lib/units'
import { cn } from '@/lib/utils'
import { NumberField } from '../ui/Input'

type BaseNumberFieldProps = ComponentProps<typeof NumberField>

/** Renders a document-mm value in editor px and converts edits back to document mm. */
export function PxNumberField({
  valueMm,
  onChangeMm,
  minMm,
  maxMm,
  precision = 1,
  ...props
}: Omit<BaseNumberFieldProps, 'value' | 'onChange' | 'min' | 'max' | 'unit'> & {
  valueMm: number | undefined
  onChangeMm: (mm: number) => void
  minMm?: number
  maxMm?: number
}) {
  return (
    <NumberField
      {...props}
      value={mmToEditorPx(valueMm ?? 0)}
      mixed={props.mixed ?? valueMm === undefined}
      min={minMm === undefined ? undefined : mmToEditorPx(minMm)}
      max={maxMm === undefined ? undefined : mmToEditorPx(maxMm)}
      precision={precision}
      unit="px"
      onChange={(px) => onChangeMm(editorPxToMm(px))}
    />
  )
}

/**
 * 编辑器几何统一以 px 输入/显示；文档模型仍保存 mm，所以只在这个 UI 边界换算。
 * 拖动改数时开事务，把连续修改合并成一条撤销记录。
 */
export function PxField({
  label,
  valueMm,
  onChangeMm,
  step = 1,
  disabled,
  historyLabel,
  minMm,
  title,
}: {
  label: string
  valueMm: number | undefined
  onChangeMm: (mm: number) => void
  step?: number
  disabled?: boolean
  /** 落进撤销栈的标签（描述符：切语言后历史跟着换） */
  historyLabel: UiMessage
  minMm?: number
  title?: string
}) {
  return (
    <PxNumberField
      fill
      prefix={label}
      prefixInside
      valueMm={valueMm}
      onChangeMm={onChangeMm}
      mixed={valueMm === undefined}
      precision={1}
      step={step}
      minMm={minMm}
      disabled={disabled}
      title={title}
      onScrubStart={() => useDocumentStore.getState().beginTxn(historyLabel)}
      onScrubEnd={() => useDocumentStore.getState().endTxn()}
    />
  )
}

/**
 * 位置与尺寸的稳定网格：两列字段中间夹一个 28px 的动作位（宽高比锁 / 横竖交换），
 * 第一行没有动作时放 `GeometrySpacer` 占位，两行的字段才对得齐。
 *
 *     X [ -347.8 px ]      Y [ -418.9 px ]
 *     W [ 1489.1 px ]  🔗  H [  980.2 px ]
 *
 * 列宽是 minmax(0,1fr)：窄栏里字段一起收窄，不会把单位挤出框外。
 */
export function GeometryGrid({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        'grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-x-1.5 gap-y-1.5',
        className,
      )}
    >
      {children}
    </div>
  )
}

export function GeometrySpacer() {
  return <span aria-hidden className="w-7" />
}
