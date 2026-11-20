import { LightningElement, api } from 'lwc';

/** Circle as a path (so every icon is a list of path strings). */
const circle = (cx, cy, r) => `M${cx - r} ${cy}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0`;

/** 24x24 line icons, 2px round strokes. */
const ICONS = {
    search: [circle(11, 11, 7), 'M20 20l-3.6-3.6'],
    x: ['M18 6 6 18', 'M6 6l12 12'],
    plus: ['M12 5v14', 'M5 12h14'],
    check: ['M20 6 9 17l-5-5'],
    minus: ['M6 12h12'],
    'chevron-right': ['m9 18 6-6-6-6'],
    'chevron-down': ['m6 9 6 6 6-6'],
    'chevron-up': ['m18 15-6-6-6 6'],
    sparkles: ['M12 3.5l1.8 4.9 4.9 1.8-4.9 1.8L12 16.9l-1.8-4.9-4.9-1.8 4.9-1.8z', 'M19 3v4', 'M21 5h-4', 'M5 17v4', 'M7 19H3'],
    undo: ['M9 14 4 9l5-5', 'M4 9h10.5a5.5 5.5 0 0 1 0 11H11'],
    reset: ['M3 12a9 9 0 1 0 3-6.7L3 8', 'M3 3v5h5'],
    bookmark: ['M19 21l-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z'],
    star: ['M12 2.8l2.8 5.7 6.3.9-4.6 4.4 1.1 6.3L12 17.1l-5.6 3 1.1-6.3L2.9 9.4l6.3-.9z'],
    filter: ['M3 5h18', 'M6 12h12', 'M10 19h4'],
    external: ['M15 3h6v6', 'M10 14 21 3', 'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6'],
    'eye-off': [
        'M3 3l18 18',
        'M10.6 10.6a2 2 0 0 0 2.8 2.8',
        'M9.4 5.2A10 10 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-2.9 3.7',
        'M6.6 6.6C3.9 8.3 2 12 2 12s3.5 7 10 7a9.6 9.6 0 0 0 5.4-1.6'
    ],
    send: ['M22 2 11 13', 'M22 2l-7 20-4-9-9-4z'],
    task: ['M9 4h6a1 1 0 0 1 1 1v1H8V5a1 1 0 0 1 1-1z', 'M8 5H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2', 'M9 14l2 2 4-4'],
    mail: ['M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z', 'M22 6l-10 7L2 6'],
    users: ['M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2', circle(9, 7, 4), 'M22 21v-2a4 4 0 0 0-3-3.9', 'M16 3.1a4 4 0 0 1 0 7.8'],
    briefcase: ['M4 7h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2z', 'M16 7V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2', 'M2 13h20'],
    columns: ['M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z', 'M12 3v18'],
    copy: ['M9 9h11v11H9z', 'M5 15H4V4h11v1'],
    'arrow-up': ['M12 19V5', 'm5 12 7-7 7 7'],
    'arrow-down': ['M12 5v14', 'm19 12-7 7-7-7'],
    history: ['M3 12a9 9 0 1 0 3-6.7L3 8', 'M3 3v5h5', 'M12 7v5l3 2'],
    pin: ['M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z', circle(12, 10, 3)],
    alert: [circle(12, 12, 10), 'M12 8v4', 'M12 16h.01'],
    ban: [circle(12, 12, 10), 'm4.9 4.9 14.2 14.2'],
    message: ['M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z'],
    code: ['m16 18 6-6-6-6', 'm8 6-6 6 6 6'],
    'file-plus': ['M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z', 'M14 3v6h6', 'M12 12v6', 'M9 15h6'],
    sliders: ['M4 21v-7', 'M4 10V3', 'M12 21v-9', 'M12 8V3', 'M20 21v-5', 'M20 12V3', 'M1 14h6', 'M9 8h6', 'M17 16h6']
};

/**
 * csIcon: inline SVG line icon. Inherits the text colour.
 * <c-cs-icon name="search" size="16"></c-cs-icon>
 */
export default class CsIcon extends LightningElement {
    @api name = 'sparkles';
    @api size = 16;
    @api strokeWidth = 2;
    /** Fill the shape too (for a filled star). */
    @api filled = false;

    get paths() {
        return (ICONS[this.name] || []).map((d, i) => ({ key: `${this.name}-${i}`, d }));
    }

    get px() {
        return String(this.size);
    }

    get fill() {
        return this.filled ? 'currentColor' : 'none';
    }

    get stroke() {
        return String(this.strokeWidth);
    }
}
