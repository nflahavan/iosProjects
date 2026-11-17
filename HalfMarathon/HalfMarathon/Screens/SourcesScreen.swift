import SwiftUI

/// Where the plan comes from and how it was checked.
struct SourcesScreen: View {
    private struct Source { let short: String; let long: String; let url: String }
    private enum Verdict: String {
        case ok = "Matches the sources", adj = "Adjusted after checking", call = "Judgment call"
        var color: Color { self == .ok ? .go : self == .adj ? .accentColor : .secondary }
    }

    private static let src: [(String, Source)] = [
        ("nhs", Source(short: "NHS Couch to 5K plan", long: "NHS. Couch to 5K running plan, week by week.", url: "https://www.nhs.uk/better-health/get-active/get-running-with-couch-to-5k/couch-to-5k-running-plan")),
        ("galloway", Source(short: "Galloway beginner half plan", long: "Jeff Galloway for runDisney. Half Marathon Beginner Training Program (PDF).", url: "https://cdn1.parksmedia.wdprapps.disney.com/media/rd/redesign/running-training-programs/runDisney-Half-Beginner-Training-Plan.pdf")),
        ("higdon", Source(short: "Higdon Novice 1", long: "Hal Higdon. Novice training programs, excerpt from Hal Higdon's Half Marathon Training (Human Kinetics).", url: "https://us.humankinetics.com/blogs/excerpt/novice-training-programs")),
        ("higdon2", Source(short: "Higdon Novice 2", long: "Hal Higdon. Half Marathon Novice 2, plan description (TrainingPeaks).", url: "https://www.trainingpeaks.com/training-plans/running/half-marathon/tp-139214/hal-higdon-1-2-marathon-novice-2")),
        ("buist", Source(short: "Buist 2008 trial", long: "Buist et al. 2008. No effect of a graded training program on running-related injuries in novice runners: randomized controlled trial. Am J Sports Med.", url: "https://research.rug.nl/en/publications/no-effect-of-a-graded-training-program-on-the-number-of-running-r/")),
        ("nielsen", Source(short: "Nielsen 2014 cohort", long: "Nielsen et al. 2014. Excessive progression in weekly running distance and risk of running-related injuries. J Orthop Sports Phys Ther.", url: "https://vbn.aau.dk/da/publications/excessive-progression-in-weekly-running-distance-and-risk-of-runn")),
        ("bosquet", Source(short: "Bosquet 2007 meta-analysis", long: "Bosquet et al. 2007. Effects of tapering on performance: a meta-analysis. Med Sci Sports Exerc.", url: "https://pubmed.ncbi.nlm.nih.gov/17762369/")),
        ("lauersen", Source(short: "Lauersen 2014 meta-analysis", long: "Lauersen et al. 2014. The effectiveness of exercise interventions to prevent sports injuries: systematic review and meta-analysis. Br J Sports Med.", url: "https://pubmed.ncbi.nlm.nih.gov/24100287/")),
        ("blagrove", Source(short: "Blagrove 2018 review", long: "Blagrove et al. 2018. Effects of strength training on the physiological determinants of middle- and long-distance running performance: systematic review. Sports Medicine.", url: "https://nrl.northumbria.ac.uk/id/eprint/33750")),
        ("ace", Source(short: "ACSM screening summary (ACE)", long: "American Council on Exercise. New preparticipation guidelines remove barriers to exercise (summary of ACSM's screening update).", url: "https://www.acefitness.org/continuing-education/certified/february-2018/6898/new-preparticipation-guidelines-remove-barriers-to-exercise")),
        ("acsm", Source(short: "ACSM stress-test brochure", long: "American College of Sports Medicine. Who needs a stress test before exercising? (PDF).", url: "https://acsm.org/docs/default-source/files-for-resource-library/cpi-who-needs-a-stress-test-before-exercising-brochure.pdf")),
    ]
    private static let byKey = Dictionary(uniqueKeysWithValues: src)

    private static let checks: [(String, Verdict, String, String, [String])] = [
        ("Run/walk start, weeks 1–9", .adj, "Now follows the NHS plan: three sessions a week, a rest day between each, 5-minute walks before and after, and 30 minutes nonstop by week 9.",
         "My first draft got to 30 minutes a week sooner and jumped from 15-minute stretches straight to 30. Weeks 3, 4 and 6 are simplified: the NHS mixes interval lengths, this uses equal ones with the same total running time.", ["nhs"]),
        ("Three runs a week with rest days between", .ok, "All three published plans are built this way. The NHS plan has three runs with a rest day between. Galloway uses Tuesday, Thursday and a weekend long run. Higdon has three run days plus an optional fourth.",
         "", ["nhs", "galloway", "higdon"]),
        ("Long run peaks at 12 miles", .ok, "Inside the published range. Higdon's novice plan tops out at 10 miles and tells runners not to worry about the jump to 13.1. Galloway's beginner plan goes to 14.",
         "Timing differs between them: Higdon's longest run is one week before the race, Galloway's is two, and this plan's is three.", ["higdon", "galloway"]),
        ("Talking pace, walk breaks allowed", .ok, "Higdon asks for a conversational pace and encourages walk breaks whenever needed, race day included. Galloway wants you able to talk for the whole long run, at least 2 minutes a mile slower than race pace.",
         "", ["higdon", "galloway"]),
        ("Goal-pace miles", .adj, "Cut back and made optional. Higdon's Novice 1 has no pace work at all; he adds midweek race-pace running only in Novice 2, for runners with more experience.",
         "The draft started goal-pace miles in week 18. They now start in week 21, there are fewer of them, and you can skip them.", ["higdon", "higdon2"]),
        ("How fast the mileage grows", .call, "The research doesn't give a safe number. A randomized trial of 532 new runners found the same injury rate with a 10%-per-week program as with a faster one, about 1 in 5 either way. A study of 874 new runners saw a trend toward more injuries when distance rose over 30% across two weeks; it did not reach statistical significance.",
         "So I kept the steps small without treating 10% as a law. From week 10 on, no week is more than 13% above your previous biggest week. Coming out of an easier week the raw two-week rise can pass 30% (week 13 to 15, for example), but that is a return to a load you have already handled plus a little. I flattened weeks 10–12 slightly after reading these.", ["buist", "nielsen"]),
        ("Easier weeks (13, 17, 20, 22)", .call, "Common coaching practice, and Galloway's plan alternates long and short weekends, but I found no trial showing that scheduled easier weeks prevent injuries.",
         "", ["galloway"]),
        ("Two-week taper", .adj, "A meta-analysis of 27 studies found the best results from a two-week taper that cuts volume by 41–60% and keeps intensity.",
         "The draft tapered for three weeks and dropped all pace work. Now it is two weeks, week 25 is 40% below the peak week, and a mile of goal pace stays in. Those studies were on competitive athletes, so treat this as a reasonable borrow, not proof for first-timers.", ["bosquet"]),
        ("Lifting twice a week", .ok, "A meta-analysis of 25 trials found strength training cut sports injuries to under a third and nearly halved overuse injuries. A review of 24 studies in distance runners concluded two to three strength sessions a week likely help performance.",
         "Caveats: the injury trials cover many sports, not new runners specifically, and the running review only included people with at least six months of running. Galloway also warns against calf-tiring work on non-run days. I kept the calf raises but the lift notes now tell you to stop leg sets with a rep or two in hand.", ["lauersen", "blagrove", "galloway"]),
        ("Holding leg weights from week 18, lighter in the taper", .call, "My judgment. I found no source that tests this for a first half marathon. The reasoning is only that the long runs are at their hardest then.",
         "", []),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("How this plan was checked") {
                        Text("Checked on Nov 15, 2026 by Claude, an AI, against three published beginner plans and the research below. No coach or clinician has reviewed it, and nothing here knows your injury or health history.")
                            .foregroundStyle(.secondary)
                    }
                    section("Before you start") {
                        card {
                            Text("The NHS plan says to speak to a doctor first if you are worried about your health.")
                            Text("Under the screening approach the American College of Sports Medicine now uses, what matters is how active you already are, whether you have symptoms or known heart, metabolic or kidney disease, and how hard you plan to go. Known disease, or symptoms such as chest pain or discomfort with activity, means get medical clearance before starting.")
                            Text("Stop any activity that causes pain and get it looked at.")
                            refs(["nhs", "ace", "acsm"])
                        }
                    }
                    section("Part by part") {
                        ForEach(Self.checks, id: \.0) { title, verdict, body, extra, keys in
                            card {
                                Text(verdict.rawValue).font(.display(13)).textCase(.uppercase)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .foregroundStyle(verdict.color)
                                    .background(verdict.color.opacity(0.15), in: .rect(cornerRadius: 6))
                                Text(title).font(.headline)
                                Text(body)
                                if !extra.isEmpty { Text(extra).foregroundStyle(.secondary) }
                                if !keys.isEmpty { refs(keys) }
                            }
                        }
                    }
                    section("What this can't tell you") {
                        card {
                            bullet("The published plans are coaches' experience. None of the three has been tested in a trial as written.")
                            bullet("Research on preventing injuries in new runners is thin. In the one trial here, about 1 in 5 had an injury that stopped them running for a week or more, whichever program they followed.")
                            bullet("I could read only an excerpt of Higdon's plan, so its week-by-week distances between weeks 1 and 11 are not checked.")
                            bullet("A plan on a page can't react to how you feel. Repeat weeks, take walk breaks, and stop for sharp pain.")
                        }
                    }
                    section("Sources") {
                        card {
                            ForEach(Array(Self.src.enumerated()), id: \.offset) { i, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(i + 1).").foregroundStyle(.secondary)
                                    Link(item.1.long, destination: URL(string: item.1.url)!).fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sources")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.display(22)).textCase(.uppercase)
            content()
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func refs(_ keys: [String]) -> some View {
        FlowLayout(spacing: 14) {
            ForEach(keys, id: \.self) { k in
                if let s = Self.byKey[k] { Link(s.short, destination: URL(string: s.url)!).fontWeight(.semibold) }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(text) }
    }
}
