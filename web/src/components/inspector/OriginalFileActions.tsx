import type { PanelObject } from '@/types/document'
import { HistoryPanel } from './HistoryPanel'
import { SyncOverridesButton } from './SyncOverridesButton'
import { UpdateSourceButton } from './UpdateSourceButton'
import { t } from '@/i18n'

/**
 * 「原始文件」组的三个动作：**一行三颗，对象页与元素页同一份**
 * （2026-09-15 全面打磨 O2）。
 *
 * 此前元素页是三颗 secondary、三种宽（102 / 228 / 336）叠成三行，对象页是两颗等宽
 * 铺满的 Grid2——同一组动作两种格式，而且三颗同权重看不出哪个才是主动作。
 * 现在权重按后果分：会覆盖磁盘原件的「写回」是 secondary，只读历史与把修改复制去
 * 兄弟图的两颗是 ghost；宽度一律按内容取，不撑满。
 */
export function OriginalFileActions({ panel }: { panel: PanelObject }) {
  // R source preservation/replay is documented in the R-specific summary above.
  // Python writeback/history APIs do not apply to an R source script.
  if (panel.script && /\.r$/i.test(panel.script)) {
    return <p className="text-xs leading-relaxed text-ink-3">{t('rAdapter.sourceReadOnly', { ns: 'inspector' })}</p>
  }
  return (
    <div className="flex flex-wrap items-center gap-1">
      {/* 写回与历史读的都是「脚本产出的那张原件」：没有脚本时它们无从谈起，
          不渲染（沿用改前两页各自的守卫，只是收到了一处） */}
      {panel.script && (
        <>
          <UpdateSourceButton panel={panel} />
          <HistoryPanel panel={panel} />
        </>
      )}
      <SyncOverridesButton panel={panel} />
    </div>
  )
}
