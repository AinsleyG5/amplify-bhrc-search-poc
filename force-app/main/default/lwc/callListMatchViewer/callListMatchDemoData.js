/**
 * Demo candidates for callListMatchViewer.
 *
 * Used only when the live match fails or returns nothing, so a demo never dies on
 * stage. Candidates use the same shape the component builds from the Apex response:
 *
 *   { id, contactId, name, title, location, status, relevance, reasons[], summary,
 *     skills[], silver:{count,detail}, engagement, redeploy:{count,detail}, vms }
 *
 * Daniel Okonkwo carries a real Contact Id from the demo org, so "Add to Call List"
 * does real DML for him. Everyone else is demo only (contactId null).
 */

const POOL_SIZE = 20;

export function poolKeyFromName(name) {
    const n = (name || '').toLowerCase();
    if (n.includes('ml') || n.includes('gcp') || n.includes('cloud') || n.includes('machine learning')) {
        return 'mlengineer';
    }
    if (n.includes('late') || n.includes('night') || n.includes('shift')) {
        return 'lateshift';
    }
    return 'driver';
}

const DANIEL = {
    id: 'cand-001',
    contactId: '003Dp00000UQV7kIAH', // real Contact Id in the demo org
    name: 'Daniel Okonkwo',
    title: 'Delivery Driver (Late Shift), Apex Swift Logistics',
    location: 'London',
    status: 'Available',
    summary: 'Four years of last-mile delivery and warehouse experience, most recently on late shifts. Full UK licence, strong record on route planning and vehicle checks.',
    skills: ['Manual Handling', 'Vehicle Safety Checks', 'Customer Service', 'Route Planning', 'Delivery Scheduling',
        'Time Management', 'Health & Safety Compliance', 'Stock Replenishment', 'Till Operations'],
    silver: { count: 1, detail: 'Shortlisted before for London Delivery Driver (Late Shift), reached Interview' },
    engagement: 88,
    redeploy: { count: 1, detail: 'Placed with this account as a Delivery Driver in 2024' },
    vms: 82
};

const SEEDS = {
    driver: [
        {
            ...DANIEL,
            relevance: 94,
            reasons: ['Recent title: Delivery Driver (Late Shift)', 'Based in London', 'Skill: Route Planning']
        },
        {
            id: 'cand-002', contactId: null, name: 'Ryan Mitchell', title: 'Courier Driver, Metro Parcel Services',
            location: 'London', status: 'Available', relevance: 81,
            reasons: ['Skill: Full UK Driving Licence (Category B)', 'Recent title: Courier Driver'],
            summary: 'Two years as a courier with handheld scanning experience. Bilingual English and Polish.',
            skills: ['Parcel Sorting', 'Customer Service', 'Manual Handling', 'Route Navigation', 'Vehicle Checks'],
            silver: { count: 0, detail: null }, engagement: 64,
            redeploy: { count: 0, detail: null }, vms: 55
        },
        {
            id: 'cand-003', contactId: null, name: 'Sana Patel', title: 'Warehouse Operative, Northgate Fulfilment',
            location: 'Greater London', status: 'Placed', relevance: 76,
            reasons: ['Skill: Manual Handling', 'Recent title: Warehouse Operative'],
            summary: 'Three years in fulfilment centres, forklift certified, strong on stock control and goods-in inspection.',
            skills: ['Manual Handling', 'Stock Control', 'Forklift Operation', 'Goods-In Inspection', 'Pallet Truck Operation'],
            silver: { count: 2, detail: 'Shortlisted before for Warehouse Operative, reached Offer (1 more prior shortlist)' },
            engagement: 45, redeploy: { count: 0, detail: null }, vms: 91
        }
    ],
    lateshift: [
        {
            ...DANIEL,
            relevance: 91,
            reasons: ['Shift pattern inferred: late and night', 'Based in London', 'Recent title: Delivery Driver (Late Shift)']
        },
        {
            id: 'cand-004', contactId: null, name: 'Jamie Kaur', title: 'Night Shift Warehouse Operative, Greenline Distribution',
            location: 'Barking', status: 'Available', relevance: 79,
            reasons: ['Recent title: Night Shift Warehouse Operative', 'Shift pattern inferred: late and night'],
            summary: 'Three years on night shifts in distribution. Reliable, adaptable, confirmed availability for nights.',
            skills: ['Night Shift Working', 'Manual Handling', 'Stock Replenishment', 'Goods-In Inspection', 'Team Coordination'],
            silver: { count: 1, detail: 'Shortlisted before for Night Shift Picker, reached Interview' },
            engagement: 72, redeploy: { count: 1, detail: 'Placed with this account as a Night Shift Operative in 2025' }, vms: 78
        },
        {
            id: 'cand-005', contactId: null, name: 'Tomasz Olek', title: 'Delivery Assistant, Ilford Home Deliveries',
            location: 'Ilford', status: 'Available', relevance: 72,
            reasons: ['Skill: available for evening shifts', 'Recent title: Delivery Assistant'],
            summary: 'One year of delivery assistant work, flexible on evenings, bilingual English and Polish.',
            skills: ['Customer Service', 'Manual Handling', 'Evening Shift Availability'],
            silver: { count: 0, detail: null }, engagement: 58,
            redeploy: { count: 0, detail: null }, vms: 48
        }
    ],
    mlengineer: [
        {
            id: 'cand-006', contactId: null, name: 'Elena Whitfield', title: 'ML Engineer, Northbridge Cloud Systems',
            location: 'London', status: 'Available', relevance: 92,
            reasons: ['Recent title: ML Engineer', 'Skill: GCP Vertex AI', 'Skill: TensorFlow'],
            summary: 'Five years building and deploying ML systems on GCP. MSc in Machine Learning, Google certified.',
            skills: ['Python', 'TensorFlow', 'GCP Vertex AI', 'Kubernetes', 'Docker', 'MLOps', 'Data Pipelines', 'CI/CD'],
            silver: { count: 1, detail: 'Shortlisted before for Cloud ML Engineer, reached Client Submittal' },
            engagement: 91, redeploy: { count: 1, detail: 'Placed with this account as an ML Engineer in 2024' }, vms: 86
        },
        {
            id: 'cand-007', contactId: null, name: 'Marcus Kimani', title: 'Cloud ML Engineer, Reading Data Labs',
            location: 'Reading', status: 'Available', relevance: 84,
            reasons: ['Recent title: Cloud ML Engineer', 'Skill: Kubernetes', 'Skill: MLOps'],
            summary: 'Four years in cloud ML engineering with a focus on model deployment and infrastructure as code.',
            skills: ['Python', 'GCP Vertex AI', 'Kubernetes', 'Terraform', 'MLOps', 'Data Pipelines', 'Model Deployment'],
            silver: { count: 0, detail: null }, engagement: 67,
            redeploy: { count: 0, detail: null }, vms: 62
        },
        {
            id: 'cand-008', contactId: null, name: 'Priya Lakhani', title: 'MLOps Engineer, Cambridge Vector Systems',
            location: 'Cambridge', status: 'Available', relevance: 77,
            reasons: ['Recent title: MLOps Engineer', 'Skill: Data Pipelines', 'Skill: CI/CD'],
            summary: 'Three years in MLOps with strong pipeline and monitoring experience.',
            skills: ['Python', 'TensorFlow', 'Docker', 'CI/CD Pipelines', 'Data Pipelines', 'Model Monitoring'],
            silver: { count: 2, detail: 'Shortlisted before for MLOps Engineer, reached Interview (1 more prior shortlist)' },
            engagement: 80, redeploy: { count: 0, detail: null }, vms: 70
        }
    ]
};

// ── Procedural fill so pagination has something to page ──────────────

const FIRST_NAMES = ['Alex', 'Jordan', 'Sam', 'Chris', 'Taylor', 'Morgan', 'Casey', 'Riley',
    'Jamie', 'Drew', 'Reese', 'Harper', 'Rowan', 'Skyler', 'Finley', 'Emerson', 'Quinn'];
const LAST_NAMES = ['Turner', 'Wallace', 'Bennett', 'Foster', 'Hayes', 'Coleman', 'Reed',
    'Sanders', 'Price', 'Nguyen', 'Osei', 'Grant', 'Doyle', 'Marsh', 'Palmer', 'Adeyemi', 'Novak'];

const POOL_PROFILE = {
    driver: {
        roles: ['Delivery Driver', 'Courier Driver', 'Van Driver', 'Multi-Drop Driver'],
        locations: ['London', 'Ilford', 'Barking', 'Romford', 'Croydon', 'Enfield', 'Dagenham'],
        employer: 'Logistics Group',
        skills: ['Manual Handling', 'Customer Service', 'Time Management', 'Route Planning', 'Health & Safety Compliance'],
        reasonSkill: 'Skill: Manual Handling',
        placedRole: 'Delivery Driver'
    },
    lateshift: {
        roles: ['Night Shift Warehouse Operative', 'Late Shift Delivery Driver', 'Evening Shift Picker', 'Overnight Stock Assistant'],
        locations: ['London', 'Ilford', 'Barking', 'Romford', 'Croydon', 'Enfield', 'Dagenham'],
        employer: 'Distribution Ltd',
        skills: ['Night Shift Working', 'Manual Handling', 'Stock Replenishment', 'Goods-In Inspection', 'Team Coordination'],
        reasonSkill: 'Shift pattern inferred: late and night',
        placedRole: 'Night Shift Operative'
    },
    mlengineer: {
        roles: ['ML Engineer', 'Machine Learning Engineer', 'Cloud ML Engineer', 'MLOps Engineer'],
        locations: ['London', 'Reading', 'Cambridge', 'Manchester', 'Bristol', 'Leeds', 'Edinburgh'],
        employer: 'Cloud Systems',
        skills: ['Python', 'TensorFlow', 'GCP Vertex AI', 'Kubernetes', 'MLOps', 'Data Pipelines', 'CI/CD'],
        reasonSkill: 'Skill: Data Pipelines',
        placedRole: 'ML Engineer'
    }
};

function generate(poolKey, idx) {
    const p = POOL_PROFILE[poolKey];
    const first = FIRST_NAMES[idx % FIRST_NAMES.length];
    const last = LAST_NAMES[(idx * 3) % LAST_NAMES.length];
    const role = p.roles[idx % p.roles.length];
    const location = p.locations[idx % p.locations.length];

    const silverCount = idx % 9 === 0 ? 2 : (idx % 4 === 1 ? 1 : 0);
    const redeployCount = idx % 5 === 2 ? 1 : 0;

    return {
        id: `${poolKey}-gen-${idx + 1}`,
        contactId: null,
        name: `${first} ${last}`,
        title: `${role}, ${last} ${p.employer}`,
        location,
        status: idx % 5 === 0 ? 'Placed' : 'Available',
        relevance: Math.max(40, 68 - idx * 2),
        reasons: [`Based in ${location}`, p.reasonSkill],
        summary: `${1 + (idx % 5)} years of relevant experience as a ${role.toLowerCase()}. Demo profile.`,
        skills: p.skills,
        silver: {
            count: silverCount,
            detail: silverCount > 0
                ? `Shortlisted before for ${role}, reached Interview` + (silverCount > 1 ? ' (1 more prior shortlist)' : '')
                : null
        },
        engagement: 30 + ((idx * 17) % 66),
        redeploy: {
            count: redeployCount,
            detail: redeployCount > 0 ? `Placed with this account as ${p.placedRole} in 2025` : null
        },
        vms: 40 + ((idx * 13) % 61)
    };
}

export function buildDemoCandidates(poolKey) {
    const key = POOL_PROFILE[poolKey] ? poolKey : 'driver';
    const seeds = SEEDS[key];
    const out = seeds.map((s) => ({ ...s }));
    for (let i = 0; out.length < POOL_SIZE; i++) {
        out.push(generate(key, i));
    }
    return out;
}