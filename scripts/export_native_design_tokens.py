"""Export a reviewable design specification; no Swift/assets or CSS mutations."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / 'design/picsee-ui-system'
ROLES = {
    'waitingIndicator': 'color-banner-unsaved',
    'canvasBackground': 'color-bg', 'sidebarBackground': 'color-surface',
    'popoverBackground': 'color-panel', 'textPrimary': 'color-text',
    'textSecondary': 'color-muted', 'divider': 'color-border',
    'dividerSubtle': 'color-border-subtle', 'hoverBackground': 'color-hover',
    'accent': 'color-accent', 'focusRing': 'color-focus-ring',
    'selectionFill': 'color-accent-soft', 'selectionText': 'color-accent-text',
    'primaryFill': 'color-accent-fill', 'primaryFillHover': 'color-accent-fill-hover',
    'onPrimary': 'color-on-accent', 'controlBorder': 'color-control-border',
    'inputBackground': 'color-input-bg', 'error': 'color-danger',
    'errorFill': 'color-danger-soft', 'errorText': 'color-error-text', 'scrim': 'color-scrim',
}

def declarations(css):
    css = re.sub(r'/\*.*?\*/', '', css, flags=re.S)
    return dict(re.findall(r'(--[\w-]+)\s*:\s*([^;{}]+)(?:;|(?=\}))', css))


def main():
    sources = [SYSTEM / 'tokens' / (mode + '.css') for mode in ('globals', 'light', 'dark')]
    sources += [SYSTEM / 'components/primitives.css', ROOT / 'design/DESIGN.md']
    parsed = {p.stem: declarations(p.read_text()) for p in sources[:3]}
    colors = {}
    for role, token in ROLES.items():
        key = '--' + token
        values = {theme: {**parsed['globals'], **parsed[theme]}[key].strip()
                  for theme in ('light', 'dark')}
        colors[role] = {'cssToken': key, 'sourceExpressions': values,
                        'nativeResolution': 'sRGB value/alias/alpha; validate before native resource generation'}
    result = {
        'schema': 'picsee.native-design-spec/v1', 'status': 'specification-only',
        'canonicalGuide': 'design/DESIGN.md', 'nativeImplementationGenerated': False,
        'sourcesSha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        'colors': colors,
        'typography': {
            role: {'cssToken': key, 'referenceSize': float(parsed['globals'][key].strip().removesuffix('px')),
                   'nativeUnit': 'pt', 'nativeFont': 'system, validate font metrics'}
            for role, key in [('uiSmall', '--font-size-ui-sm'), ('ui', '--font-size-ui'),
                             ('uiLarge', '--font-size-ui-lg'), ('title', '--font-size-title')]
        },
        'customRadii': {role: {'cssToken': '--radius-' + role,
                               'referenceSize': float(parsed['globals']['--radius-' + role].strip().removesuffix('px')),
                               'nativeUnit': 'pt'} for role in ('inner', 'control', 'popover')},
        'layoutReferences': {
            'source': 'Accepted C mockups and design/DESIGN.md; native system metrics may differ',
            'spacingPt': [4, 8, 12, 16, 24], 'iconPt': [16, 18],
            'iconButtonHitAreaPt': [30, 28], 'gridBottomBarPt': 40,
            'sidebarInitialPt': [196, 220], 'sidebarRangePt': [160, 320],
            'inspectorInitialPt': 220, 'viewerFitMarginPt': 16,
            'webTitleStripReferencePx': 38, 'nativeTitlebarHeight': 'system-defined',
        },
        'behaviorReferences': {'viewerIdleDelaySeconds': 2.5, 'shortTransitionSeconds': 0.15,
                               'reducedMotionTransitionSeconds': 0, 'timerOwner': 'MadoApplication'},
        'legacyExclusion': ['editor-*', 'color-editor-bg', 'color-code-bg', 'color-highlight',
                            'bottom-tabs-height', 'traffic-lights-*', 'color-running-*',
                            'unused aliases'],
    }
    output = SYSTEM / 'native/TOKEN_REGISTRY.json'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f'Exported {len(colors)} native color roles; specification only: {output.relative_to(ROOT)}')

if __name__ == '__main__':
    main()
