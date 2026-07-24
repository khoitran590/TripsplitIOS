import SwiftUI
import MapKit

struct Destination: Identifiable {
    let id: String
    let title: String
    let city: String
    let country: String
    let tags: [String]
    let planner: String
    let price: String
    let dailyBudget: String
    let stops: Int
    let isFeatured: Bool
    let symbol: String
    let colors: [Color]
    let places: [TravelPlanItem]
    let restaurants: [TravelPlanItem]
    let plannerNote: String
}

struct TravelPlanItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let cost: String
}

extension Destination {
    /// Curated city and resort guides across the app's supported regions.
    static let all: [Destination] = [
        // Asia
        Destination(
            id: "tokyo",
            title: "Tokyo Adventure", city: "Tokyo", country: "Japan",
            tags: ["5 days", "Urban"], planner: "Yuki Tanaka", price: "$2.5k",
            dailyBudget: "~$500/day", stops: 13, isFeatured: true, symbol: "building.2.fill",
            colors: [.pink, .purple],
            places: [
                TravelPlanItem(name: "Asakusa & Senso-ji", detail: "Temple morning, Nakamise snacks, Sumida river walk.", cost: "Low"),
                TravelPlanItem(name: "Shibuya + Harajuku", detail: "Crossing, Meiji Jingu, Cat Street, compact shopping loop.", cost: "Low-mid"),
                TravelPlanItem(name: "Ueno Park", detail: "Museums, Ameyoko market, easy rainy-day backup.", cost: "Low-mid"),
                TravelPlanItem(name: "Toyosu or Tsukiji", detail: "Market breakfast and waterfront afternoon.", cost: "Mid"),
                TravelPlanItem(name: "teamLab Planets", detail: "Immersive digital art in Toyosu; book a timed slot online.", cost: "Mid"),
                TravelPlanItem(name: "Shinjuku at night", detail: "Free Metropolitan Government observatory, then Omoide Yokocho lanterns.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Uogashi Nihon-Ichi", detail: "Standing sushi for a fast market-style lunch.", cost: "$$"),
                TravelPlanItem(name: "Ichiran Shibuya", detail: "Solo-booth ramen that keeps dinner predictable.", cost: "$"),
                TravelPlanItem(name: "Afuri Harajuku", detail: "Light yuzu-shio ramen between Harajuku shopping stops.", cost: "$-$$"),
                TravelPlanItem(name: "Tsukiji Outer Market stalls", detail: "Share grilled seafood, tamagoyaki, and onigiri.", cost: "$-$$")
            ],
            plannerNote: "Stay near Ueno, Shinjuku, or Ginza to keep train hops short."
        ),
        Destination(
            id: "kyoto",
            title: "Kyoto Serenity", city: "Kyoto", country: "Japan",
            tags: ["4 days", "Culture"], planner: "Haru Sato", price: "$1.9k",
            dailyBudget: "~$475/day", stops: 11, isFeatured: false, symbol: "leaf.fill",
            colors: [.green, .teal],
            places: [
                TravelPlanItem(name: "Fushimi Inari", detail: "Go early for the lower gates, then climb as far as energy allows.", cost: "Low"),
                TravelPlanItem(name: "Higashiyama", detail: "Kiyomizu-dera, Sannenzaka lanes, evening Gion stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Arashiyama", detail: "Bamboo grove, river walk, Tenryu-ji garden.", cost: "Mid"),
                TravelPlanItem(name: "Nishiki Market", detail: "Snack crawl that doubles as lunch.", cost: "$"),
                TravelPlanItem(name: "Kinkaku-ji", detail: "The Golden Pavilion; pair with Ryoan-ji's rock garden nearby.", cost: "Low"),
                TravelPlanItem(name: "Philosopher's Path", detail: "Canal-side walk linking Ginkaku-ji to Nanzen-ji's gate.", cost: "Free")
            ],
            restaurants: [
                TravelPlanItem(name: "Omen Ginkakuji", detail: "Kyoto udon near the Philosopher's Path.", cost: "$$"),
                TravelPlanItem(name: "Gyoza Hohei", detail: "Cult gyoza spot in Gion; go early to dodge the line.", cost: "$-$$"),
                TravelPlanItem(name: "Honke Owariya", detail: "Historic soba for a calm lunch near central Kyoto.", cost: "$$"),
                TravelPlanItem(name: "Nishiki Market stalls", detail: "Budget bites: skewers, tofu doughnuts, pickles.", cost: "$")
            ],
            plannerNote: "Split the city by area; crossing Kyoto repeatedly costs more time than money."
        ),
        Destination(
            id: "seoul",
            title: "Seoul Nights", city: "Seoul", country: "South Korea",
            tags: ["6 days", "Foodie"], planner: "Min-jun Park", price: "$2.1k",
            dailyBudget: "~$350/day", stops: 13, isFeatured: true, symbol: "sparkles",
            colors: [.indigo, .blue],
            places: [
                TravelPlanItem(name: "Gyeongbokgung + Bukchon", detail: "Palace morning, hanok alleys, tea-house break.", cost: "Low-mid"),
                TravelPlanItem(name: "Namsan Seoul Tower", detail: "Golden-hour city views with an easy cable-car option.", cost: "Mid"),
                TravelPlanItem(name: "Ikseon-dong", detail: "Small-lane cafes, design shops, relaxed evening stroll.", cost: "Low-mid"),
                TravelPlanItem(name: "Gwangjang Market", detail: "Classic food market for mung bean pancakes and noodles.", cost: "$"),
                TravelPlanItem(name: "Changdeokgung Secret Garden", detail: "Guided garden tour behind the prettiest palace; book ahead.", cost: "Mid"),
                TravelPlanItem(name: "Hongdae", detail: "Street performers, vintage shops, and late-night snack streets.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Myeongdong Kyoja", detail: "Kalguksu and mandu in a central, efficient stop.", cost: "$"),
                TravelPlanItem(name: "Tosokchon Samgyetang", detail: "Ginseng chicken soup a short walk from Gyeongbokgung.", cost: "$$"),
                TravelPlanItem(name: "Hadongkwan", detail: "Old-school gomtang lunch near Myeongdong.", cost: "$$"),
                TravelPlanItem(name: "Gwangjang Market stalls", detail: "Share bindaetteok, mayak gimbap, and hotteok.", cost: "$")
            ],
            plannerNote: "Base in Myeongdong, Jongno, or Hongdae depending on whether food, palaces, or nightlife matters most."
        ),
        Destination(
            id: "bangkok",
            title: "Bangkok Escape", city: "Bangkok", country: "Thailand",
            tags: ["5 days", "Markets"], planner: "Anong Wong", price: "$1.4k",
            dailyBudget: "~$280/day", stops: 12, isFeatured: false, symbol: "sun.max.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Grand Palace + Wat Pho", detail: "Classic old-city morning before the heat peaks.", cost: "Mid"),
                TravelPlanItem(name: "Wat Arun", detail: "Cross-river temple stop, best paired with sunset.", cost: "Low"),
                TravelPlanItem(name: "Jim Thompson House", detail: "Shaded culture stop near central transit.", cost: "Mid"),
                TravelPlanItem(name: "Chatuchak Weekend Market", detail: "Half-day market crawl for gifts, clothing, and snacks.", cost: "$"),
                TravelPlanItem(name: "Chao Phraya at dusk", detail: "Orange-flag ferry hop past lit temples; get off at ICONSIAM.", cost: "Low"),
                TravelPlanItem(name: "Talad Rot Fai Srinakarin", detail: "Retro night market for vintage stalls and street food.", cost: "$")
            ],
            restaurants: [
                TravelPlanItem(name: "Thipsamai", detail: "Pad thai near the old city for a structured dinner stop.", cost: "$$"),
                TravelPlanItem(name: "Somtum Der", detail: "Isan som tam and grilled chicken done properly.", cost: "$-$$"),
                TravelPlanItem(name: "Polo Fried Chicken", detail: "Garlic fried chicken and som tam near Lumphini.", cost: "$"),
                TravelPlanItem(name: "Or Tor Kor Market", detail: "Clean market grazing with fruit, curry, and sweets.", cost: "$-$$")
            ],
            plannerNote: "Use river boats for the old city and BTS/MRT for Sukhumvit/Silom days."
        ),
        Destination(
            id: "singapore",
            title: "Singapore Skyline", city: "Singapore", country: "Singapore",
            tags: ["3 days", "Modern"], planner: "Wei Lim", price: "$2.8k",
            dailyBudget: "~$930/day", stops: 10, isFeatured: true, symbol: "building.columns.fill",
            colors: [.teal, .cyan],
            places: [
                TravelPlanItem(name: "Gardens by the Bay", detail: "Supertree Grove plus one conservatory if weather turns.", cost: "Mid"),
                TravelPlanItem(name: "Marina Bay loop", detail: "Merlion, skyline walk, evening light show.", cost: "Low"),
                TravelPlanItem(name: "Kampong Glam", detail: "Sultan Mosque, Haji Lane, indie shops.", cost: "Low"),
                TravelPlanItem(name: "Singapore Botanic Gardens", detail: "Green reset and Orchid Garden add-on.", cost: "Low-mid"),
                TravelPlanItem(name: "Sentosa", detail: "Cable car in, beach afternoon, Skyline Luge if traveling with kids.", cost: "Mid"),
                TravelPlanItem(name: "Little India", detail: "Sri Veeramakaliamman Temple, Tekka Centre, and Mustafa's aisles.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Maxwell Food Centre", detail: "Chicken rice, popiah, and herbal soups under one roof.", cost: "$"),
                TravelPlanItem(name: "Song Fa Bak Kut Teh", detail: "Peppery pork-rib soup with free broth refills.", cost: "$-$$"),
                TravelPlanItem(name: "Lau Pa Sat Satay Street", detail: "Open-air skewers after the Marina Bay walk.", cost: "$"),
                TravelPlanItem(name: "Old Airport Road Food Centre", detail: "Local hawker dinner with broad choices.", cost: "$")
            ],
            plannerNote: "Keep hotels central; meals can stay affordable by leaning into hawker centres."
        ),
        Destination(
            id: "bali",
            title: "Bali Bliss", city: "Bali", country: "Indonesia",
            tags: ["7 days", "Beach"], planner: "Kadek Putra", price: "$1.6k",
            dailyBudget: "~$230/day", stops: 14, isFeatured: false, symbol: "beach.umbrella.fill",
            colors: [.mint, .green],
            places: [
                TravelPlanItem(name: "Ubud", detail: "Monkey Forest, art market, rice-field walks.", cost: "Low-mid"),
                TravelPlanItem(name: "Tirta Empul", detail: "Temple visit with respectful timing and dress.", cost: "Low"),
                TravelPlanItem(name: "Tegallalang", detail: "Rice terraces and cafe viewpoints.", cost: "Low-mid"),
                TravelPlanItem(name: "Uluwatu", detail: "Clifftop temple, beaches, sunset kecak performance.", cost: "Mid"),
                TravelPlanItem(name: "Nusa Penida day trip", detail: "Fast boat to Kelingking cliff and Crystal Bay snorkeling.", cost: "Mid-high"),
                TravelPlanItem(name: "Canggu", detail: "Beginner surf lessons, beach clubs, and sunset at Batu Bolong.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Warung Biah Biah", detail: "Balinese small plates in Ubud.", cost: "$"),
                TravelPlanItem(name: "Milk & Madu", detail: "Reliable brunch stop between Canggu beach sessions.", cost: "$$"),
                TravelPlanItem(name: "Nasi Ayam Kedewatan Ibu Mangku", detail: "Classic chicken rice plate.", cost: "$"),
                TravelPlanItem(name: "Warung Nia", detail: "Satay and Balinese staples near Seminyak.", cost: "$-$$")
            ],
            plannerNote: "Do Ubud first, then finish near the coast so beach days absorb any weather delays."
        ),

        Destination(
            id: "osaka",
            title: "Osaka Appetite", city: "Osaka", country: "Japan",
            tags: ["3 days", "Foodie"], planner: "Ren Nakamura", price: "$1.5k",
            dailyBudget: "~$500/day", stops: 9, isFeatured: true, symbol: "fork.knife",
            colors: [.red, .pink],
            places: [
                TravelPlanItem(name: "Dotonbori + Namba", detail: "Neon canal, the Glico sign, and street snacks every ten steps.", cost: "Low"),
                TravelPlanItem(name: "Osaka Castle", detail: "Park grounds are the highlight; the museum inside is optional.", cost: "Low-mid"),
                TravelPlanItem(name: "Kuromon Ichiba Market", detail: "Grazing breakfast of scallops, tuna, and fresh fruit.", cost: "$-$$"),
                TravelPlanItem(name: "Shinsekai", detail: "Retro Tsutenkaku tower district and kushikatsu alleys.", cost: "Low"),
                TravelPlanItem(name: "Umeda Sky Building", detail: "Open-air rooftop ring for sunset over the city grid.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Mizuno", detail: "Michelin-listed okonomiyaki worth the Dotonbori queue.", cost: "$$"),
                TravelPlanItem(name: "Takoyaki Wanaka", detail: "Textbook takoyaki from a Namba institution.", cost: "$"),
                TravelPlanItem(name: "Daruma Shinsekai", detail: "The original kushikatsu — no double-dipping the sauce.", cost: "$-$$"),
                TravelPlanItem(name: "Kuromon Market stalls", detail: "Wagyu skewers and sea urchin straight off the ice.", cost: "$$")
            ],
            plannerNote: "Osaka is a food city first — plan the sights around meals, not the other way around."
        ),
        Destination(
            id: "taipei",
            title: "Taipei Lights", city: "Taipei", country: "Taiwan",
            tags: ["4 days", "Night markets"], planner: "Wei-Ting Chen", price: "$1.3k",
            dailyBudget: "~$325/day", stops: 10, isFeatured: false, symbol: "moon.stars.fill",
            colors: [.teal, .green],
            places: [
                TravelPlanItem(name: "Taipei 101 + Xinyi", detail: "Observatory views, then mall-district people watching.", cost: "Mid"),
                TravelPlanItem(name: "Elephant Mountain", detail: "Short stair hike for the classic skyline shot at sunset.", cost: "Free"),
                TravelPlanItem(name: "National Palace Museum", detail: "Imperial treasures; two focused hours beat a full day.", cost: "Mid"),
                TravelPlanItem(name: "Beitou Hot Springs", detail: "Thermal valley and public baths at the end of the metro line.", cost: "Low-mid"),
                TravelPlanItem(name: "Jiufen day trip", detail: "Lantern-lined teahouse lanes in the hills; go on a weekday.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Din Tai Fung Xinyi", detail: "The original xiao long bao flagship; queue moves fast.", cost: "$$"),
                TravelPlanItem(name: "Raohe Night Market", detail: "Start with the pepper buns at the temple-side entrance.", cost: "$"),
                TravelPlanItem(name: "Yongkang Beef Noodle", detail: "Braised beef noodle soup benchmark near Dongmen.", cost: "$"),
                TravelPlanItem(name: "Shilin Night Market", detail: "Fried chicken cutlets, stinky tofu, and bubble tea rounds.", cost: "$")
            ],
            plannerNote: "Grab an EasyCard on arrival — the MRT plus night markets keep days cheap and evenings full."
        ),

        // Europe
        Destination(
            id: "paris",
            title: "Paris Icons", city: "Paris", country: "France",
            tags: ["5 days", "Romantic"], planner: "Camille Laurent", price: "$3.0k",
            dailyBudget: "~$600/day", stops: 11, isFeatured: true, symbol: "sparkles",
            colors: [.blue, .purple],
            places: [
                TravelPlanItem(name: "Eiffel Tower + Trocadéro", detail: "Cross the river for the classic view, then picnic on the Champ de Mars.", cost: "Mid"),
                TravelPlanItem(name: "Louvre + Tuileries", detail: "Book a timed entry, pick one wing, and exit through the gardens.", cost: "Mid"),
                TravelPlanItem(name: "Montmartre", detail: "Sacré-Cœur steps, artist square, and winding back lanes.", cost: "Low"),
                TravelPlanItem(name: "Le Marais", detail: "Place des Vosges, boutiques, and falafel on Rue des Rosiers.", cost: "Low-mid"),
                TravelPlanItem(name: "Seine at sunset", detail: "Walk Pont Neuf to Pont Alexandre III as the lights come on.", cost: "Free"),
                TravelPlanItem(name: "Musée d'Orsay", detail: "Impressionists in a Beaux-Arts train station; quieter than the Louvre.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "L'As du Fallafel", detail: "The Marais falafel line that moves faster than it looks.", cost: "$"),
                TravelPlanItem(name: "Bouillon Chartier", detail: "1896 dining hall with white tablecloths at canteen prices.", cost: "$$"),
                TravelPlanItem(name: "Breizh Café", detail: "Buckwheat galettes and salted-caramel crêpes.", cost: "$$"),
                TravelPlanItem(name: "Boulangerie picnic", detail: "Baguette, cheese, and fruit — the best lunch deal in Paris.", cost: "$")
            ],
            plannerNote: "Cluster days by arrondissement and buy museum tickets online — queues cost more than the metro ever will."
        ),
        Destination(
            id: "rome",
            title: "Roman Holiday", city: "Rome", country: "Italy",
            tags: ["4 days", "History"], planner: "Giulia Conti", price: "$2.2k",
            dailyBudget: "~$550/day", stops: 10, isFeatured: false, symbol: "building.columns.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Colosseum + Forum", detail: "One combined ticket covers both plus Palatine Hill; go at opening.", cost: "Mid"),
                TravelPlanItem(name: "Pantheon + Piazza Navona", detail: "Free dome wonder, then fountains and evening passeggiata.", cost: "Low"),
                TravelPlanItem(name: "Vatican Museums", detail: "Early-entry slot for the Sistine Chapel, then St. Peter's.", cost: "Mid-high"),
                TravelPlanItem(name: "Trastevere", detail: "Cobbled lanes and trattorie across the river; best after dark.", cost: "Low"),
                TravelPlanItem(name: "Trevi + Spanish Steps", detail: "Do the famous fountains before 8am or after midnight.", cost: "Free")
            ],
            restaurants: [
                TravelPlanItem(name: "Trapizzino", detail: "Pizza-pocket street food filled with Roman stews.", cost: "$"),
                TravelPlanItem(name: "Pizzarium Bonci", detail: "Cult pizza al taglio near the Vatican, sold by weight.", cost: "$"),
                TravelPlanItem(name: "Tonnarello", detail: "Cacio e pepe and carbonara staples in Trastevere.", cost: "$$"),
                TravelPlanItem(name: "Giolitti", detail: "Historic gelato counter near the Pantheon.", cost: "$")
            ],
            plannerNote: "Walk the center, book the Vatican and Colosseum ahead, and eat dinner late like the locals."
        ),
        Destination(
            id: "barcelona",
            title: "Barcelona Color", city: "Barcelona", country: "Spain",
            tags: ["4 days", "Design"], planner: "Marta Vidal", price: "$2.0k",
            dailyBudget: "~$500/day", stops: 10, isFeatured: false, symbol: "paintpalette.fill",
            colors: [.yellow, .orange],
            places: [
                TravelPlanItem(name: "Sagrada Família", detail: "Book a timed slot with tower access; mornings get the best light.", cost: "Mid"),
                TravelPlanItem(name: "Gothic Quarter + El Born", detail: "Cathedral cloister, Roman walls, and tapas alleys.", cost: "Low"),
                TravelPlanItem(name: "Park Güell", detail: "Gaudí's mosaic terrace over the city; reserve the monumental zone.", cost: "Low-mid"),
                TravelPlanItem(name: "Barceloneta", detail: "Beachfront promenade ending in seafood and vermouth.", cost: "Free"),
                TravelPlanItem(name: "Montjuïc", detail: "Cable car up for castle views, gardens, and the Magic Fountain.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "La Cova Fumada", detail: "The Barceloneta counter that invented the bomba.", cost: "$-$$"),
                TravelPlanItem(name: "Bar del Pla", detail: "Modern tapas near the Picasso Museum.", cost: "$$"),
                TravelPlanItem(name: "La Boqueria stalls", detail: "Market juice, jamón cones, and counter seafood off La Rambla.", cost: "$-$$"),
                TravelPlanItem(name: "Bo de B", detail: "Legendary cheap sandwich stop near the marina.", cost: "$")
            ],
            plannerNote: "Book the Gaudí sites days ahead; everything else works best as unplanned neighborhood wandering."
        ),
        Destination(
            id: "london",
            title: "London Classics", city: "London", country: "UK",
            tags: ["5 days", "Classic"], planner: "James Whitfield", price: "$3.1k",
            dailyBudget: "~$620/day", stops: 11, isFeatured: false, symbol: "crown.fill",
            colors: [.indigo, .purple],
            places: [
                TravelPlanItem(name: "Westminster + South Bank", detail: "Big Ben, the Eye, and a riverside walk to the Globe.", cost: "Low"),
                TravelPlanItem(name: "British Museum", detail: "Rosetta Stone and the Parthenon rooms — completely free.", cost: "Free"),
                TravelPlanItem(name: "Tower of London + Tower Bridge", detail: "Crown Jewels early, then the bridge's glass walkway.", cost: "Mid-high"),
                TravelPlanItem(name: "Borough Market + Bankside", detail: "Graze the market, then Tate Modern's free viewing level.", cost: "$-$$"),
                TravelPlanItem(name: "Notting Hill", detail: "Pastel terraces and Portobello Road's Saturday antiques.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Dishoom", detail: "Bombay café classics; walk-ins move quickly before noon.", cost: "$$"),
                TravelPlanItem(name: "Borough Market stalls", detail: "Toasted cheese, oysters, and curry pots under the arches.", cost: "$-$$"),
                TravelPlanItem(name: "Padella", detail: "Fresh pasta by London Bridge at pub prices.", cost: "$$"),
                TravelPlanItem(name: "The Regency Café", detail: "Full English at a 1946 caff institution.", cost: "$")
            ],
            plannerNote: "The big museums are free — spend the savings on one paid icon and a West End night."
        ),
        Destination(
            id: "lisbon",
            title: "Lisbon Hills", city: "Lisbon", country: "Portugal",
            tags: ["4 days", "Coastal"], planner: "Inês Ferreira", price: "$1.7k",
            dailyBudget: "~$425/day", stops: 10, isFeatured: false, symbol: "tram.fill",
            colors: [.cyan, .blue],
            places: [
                TravelPlanItem(name: "Alfama + Tram 28", detail: "Ride the vintage tram early, then wander down from the castle.", cost: "Low"),
                TravelPlanItem(name: "Belém", detail: "Tower, Jerónimos Monastery, and the original pastéis bakery.", cost: "Low-mid"),
                TravelPlanItem(name: "Bairro Alto miradouros", detail: "Sunset viewpoint crawl with kiosk drinks between terraces.", cost: "Free"),
                TravelPlanItem(name: "LX Factory", detail: "Industrial complex of bookshops, murals, and brunch spots.", cost: "Low-mid"),
                TravelPlanItem(name: "Sintra day trip", detail: "Pena Palace and Quinta da Regaleira; give it a full day.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Pastéis de Belém", detail: "The 1837 custard-tart original, still warm with cinnamon.", cost: "$"),
                TravelPlanItem(name: "Time Out Market", detail: "Lisbon's best-of food hall under one roof.", cost: "$$"),
                TravelPlanItem(name: "Taberna da Rua das Flores", detail: "Chalkboard petiscos in a tiny Chiado tavern.", cost: "$$"),
                TravelPlanItem(name: "Cervejaria Ramiro", detail: "Garlic prawns and beer at the famous seafood hall.", cost: "$$")
            ],
            plannerNote: "Wear real shoes for the hills, ride Tram 28 before the crowds, and save Sintra for a clear day."
        ),

        // North America
        Destination(
            id: "new-york",
            title: "New York Buzz", city: "New York", country: "USA",
            tags: ["5 days", "Urban"], planner: "Olivia Brooks", price: "$3.2k",
            dailyBudget: "~$640/day", stops: 17, isFeatured: true, symbol: "building.2.fill",
            colors: [.blue, .indigo],
            places: [
                TravelPlanItem(name: "Central Park + The Met", detail: "Classic uptown day with picnic flexibility.", cost: "Low-mid"),
                TravelPlanItem(name: "Staten Island Ferry", detail: "Free skyline and harbor view.", cost: "Free"),
                TravelPlanItem(name: "Brooklyn Bridge + DUMBO", detail: "Walk the bridge, then waterfront views.", cost: "Low"),
                TravelPlanItem(name: "High Line + Chelsea Market", detail: "Easy west-side afternoon with food options.", cost: "Low-mid"),
                TravelPlanItem(name: "Lower Manhattan", detail: "9/11 Memorial, the Oculus, and Stone Street's pub lane.", cost: "Low-mid"),
                TravelPlanItem(name: "Williamsburg", detail: "Waterfront skyline views, vintage shops, weekend Smorgasburg.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Xi'an Famous Foods", detail: "Hand-ripped noodles and cumin lamb for a quick meal.", cost: "$"),
                TravelPlanItem(name: "Joe's Pizza", detail: "The Greenwich Village slice benchmark, open late.", cost: "$"),
                TravelPlanItem(name: "Los Tacos No. 1", detail: "Reliable taco stop near Chelsea or Times Square.", cost: "$"),
                TravelPlanItem(name: "Mamoun's Falafel", detail: "Late-night Greenwich Village budget classic.", cost: "$")
            ],
            plannerNote: "Buy fewer paid attractions and spend the savings on one Broadway or observation-deck night."
        ),
        Destination(
            id: "san-francisco",
            title: "Golden Gate Days", city: "San Francisco", country: "USA",
            tags: ["4 days", "Coastal"], planner: "Liam Carter", price: "$2.7k",
            dailyBudget: "~$675/day", stops: 12, isFeatured: false, symbol: "water.waves",
            colors: [.orange, .pink],
            places: [
                TravelPlanItem(name: "Golden Gate Bridge + Presidio", detail: "Bridge views, Tunnel Tops, Crissy Field.", cost: "Low"),
                TravelPlanItem(name: "Ferry Building", detail: "Waterfront walk and local food hall grazing.", cost: "$-$$"),
                TravelPlanItem(name: "Mission District", detail: "Murals, Dolores Park, taqueria crawl.", cost: "Low"),
                TravelPlanItem(name: "Lands End", detail: "Coastal trail, Sutro Baths, ocean views.", cost: "Free"),
                TravelPlanItem(name: "Alcatraz", detail: "Book the ferry weeks ahead; the audio tour is the best part.", cost: "Mid"),
                TravelPlanItem(name: "Golden Gate Park", detail: "de Young tower views, Japanese Tea Garden, bison paddock.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Good Mong Kok Bakery", detail: "Chinatown dim sum picnic box.", cost: "$"),
                TravelPlanItem(name: "Burma Superstar", detail: "Tea-leaf salad and garlic noodles in the Richmond.", cost: "$$"),
                TravelPlanItem(name: "Taqueria Cancun", detail: "Mission burritos that keep dinner inexpensive.", cost: "$"),
                TravelPlanItem(name: "Tadu Ethiopian Kitchen", detail: "Generous Ethiopian plates near downtown.", cost: "$-$$")
            ],
            plannerNote: "Pack layers, cluster by neighborhood, and use Muni day passes instead of rideshares."
        ),
        Destination(
            id: "vancouver",
            title: "Vancouver Wild", city: "Vancouver", country: "Canada",
            tags: ["6 days", "Nature"], planner: "Emma Wilson", price: "$2.3k",
            dailyBudget: "~$385/day", stops: 13, isFeatured: true, symbol: "mountain.2.fill",
            colors: [.green, .blue],
            places: [
                TravelPlanItem(name: "Stanley Park Seawall", detail: "Bike or walk the waterfront loop.", cost: "Low"),
                TravelPlanItem(name: "Granville Island", detail: "Public Market lunch and waterfront ferries.", cost: "$-$$"),
                TravelPlanItem(name: "Lynn Canyon", detail: "Forest trails and suspension bridge alternative.", cost: "Low"),
                TravelPlanItem(name: "Gastown + Chinatown", detail: "Historic streets, coffee stops, evening food.", cost: "Low-mid"),
                TravelPlanItem(name: "Grouse Mountain", detail: "Skyride up for city-to-ocean views; hike the Grind if fit.", cost: "Mid-high"),
                TravelPlanItem(name: "Kitsilano Beach", detail: "Sunset beach with mountain backdrop and a heated saltwater pool.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Japadog", detail: "Fast Vancouver street-food classic.", cost: "$"),
                TravelPlanItem(name: "Phnom Penh", detail: "Butter beef and famous chicken wings in Chinatown.", cost: "$$"),
                TravelPlanItem(name: "Meat & Bread", detail: "Simple sandwiches near downtown sights.", cost: "$"),
                TravelPlanItem(name: "Granville Island Public Market", detail: "Shareable stalls for lunch variety.", cost: "$-$$")
            ],
            plannerNote: "Use downtown as a base; reserve one flexible day for mountain weather."
        ),
        Destination(
            id: "las-vegas",
            title: "Vegas Lights", city: "Las Vegas", country: "USA",
            tags: ["3 days", "Nightlife"], planner: "Noah Reed", price: "$2.0k",
            dailyBudget: "~$665/day", stops: 9, isFeatured: false, symbol: "sparkles",
            colors: [.purple, .pink],
            places: [
                TravelPlanItem(name: "Bellagio Fountains + Strip walk", detail: "Free classic Vegas loop after sunset.", cost: "Free"),
                TravelPlanItem(name: "Neon Museum", detail: "Design-heavy history stop; book ahead.", cost: "Mid"),
                TravelPlanItem(name: "Fremont Street", detail: "Downtown lights, street performers, cheaper drinks.", cost: "Low-mid"),
                TravelPlanItem(name: "Red Rock Canyon", detail: "Half-day nature reset by car or tour.", cost: "Mid"),
                TravelPlanItem(name: "Sphere", detail: "The immersive venue is worth one splurge show or Experience.", cost: "Mid-high"),
                TravelPlanItem(name: "Hoover Dam", detail: "Classic half-day drive; walk the top for free canyon views.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Tacos El Gordo", detail: "Fast adobada tacos near the north Strip.", cost: "$"),
                TravelPlanItem(name: "Shang Artisan Noodle", detail: "Hand-pulled noodles that beat any buffet for the price.", cost: "$"),
                TravelPlanItem(name: "Ellis Island BBQ", detail: "Off-Strip comfort food and local beer.", cost: "$-$$"),
                TravelPlanItem(name: "Lotus of Siam", detail: "Northern Thai lunch or shared dinner.", cost: "$$")
            ],
            plannerNote: "Spend on one show, then use free Strip sights and off-Strip meals to hold the budget."
        ),
        Destination(
            id: "mexico-city",
            title: "Mexico City Soul", city: "Mexico City", country: "Mexico",
            tags: ["5 days", "Culture"], planner: "Sofía Ramírez", price: "$1.5k",
            dailyBudget: "~$300/day", stops: 14, isFeatured: false, symbol: "sun.max.fill",
            colors: [.red, .orange],
            places: [
                TravelPlanItem(name: "Centro Histórico", detail: "Zocalo, cathedral, Palacio de Bellas Artes.", cost: "Low"),
                TravelPlanItem(name: "Chapultepec", detail: "Castle, park, Anthropology Museum.", cost: "Low-mid"),
                TravelPlanItem(name: "Coyoacan", detail: "Plazas, markets, Frida Kahlo Museum area.", cost: "Mid"),
                TravelPlanItem(name: "Roma + Condesa", detail: "Parks, galleries, cafes, dinner walk.", cost: "Low-mid"),
                TravelPlanItem(name: "Teotihuacan", detail: "Pyramid day trip; leave early and beat the midday sun.", cost: "Mid"),
                TravelPlanItem(name: "Xochimilco", detail: "Trajinera boat party through the canals — best with a group.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Taqueria Orinoco", detail: "Tacos norteños for an easy Roma/Condesa dinner.", cost: "$"),
                TravelPlanItem(name: "Churrería El Moro", detail: "Churros and hot chocolate, open around the clock downtown.", cost: "$"),
                TravelPlanItem(name: "El Huequito", detail: "Al pastor classic near central sightseeing.", cost: "$"),
                TravelPlanItem(name: "Tostadas Coyoacan", detail: "Market tostadas before or after museum time.", cost: "$")
            ],
            plannerNote: "Use rideshare at night, keep museum days early, and leave room for spontaneous taco stops."
        ),
        Destination(
            id: "honolulu",
            title: "Honolulu Waves", city: "Honolulu", country: "USA",
            tags: ["6 days", "Beach"], planner: "Malia Kealoha", price: "$3.4k",
            dailyBudget: "~$570/day", stops: 9, isFeatured: true, symbol: "beach.umbrella.fill",
            colors: [.cyan, .blue],
            places: [
                TravelPlanItem(name: "Waikiki Beach", detail: "Gentle rollers made for a first surf lesson or outrigger ride.", cost: "Low-mid"),
                TravelPlanItem(name: "Diamond Head", detail: "Crater-rim sunrise hike; out-of-state visitors reserve online.", cost: "Low"),
                TravelPlanItem(name: "Pearl Harbor", detail: "Free timed tickets for the Arizona Memorial go fast — book early.", cost: "Low-mid"),
                TravelPlanItem(name: "Hanauma Bay", detail: "Best beginner snorkeling on Oahu; reservations open two days out.", cost: "Mid"),
                TravelPlanItem(name: "North Shore day trip", detail: "Haleiwa town, turtle beaches, and winter big-wave watching.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Ono Seafood", detail: "Made-to-order poke bowls worth the walk from Waikiki.", cost: "$"),
                TravelPlanItem(name: "Marukame Udon", detail: "Fresh-pulled udon line that moves fast on Kuhio Ave.", cost: "$"),
                TravelPlanItem(name: "Helena's Hawaiian Food", detail: "James Beard-winning kalua pig and pipikaula since 1946.", cost: "$$"),
                TravelPlanItem(name: "Leonard's Bakery", detail: "Hot malasadas — order the haupia filling.", cost: "$")
            ],
            plannerNote: "Reserve Hanauma Bay and Diamond Head online days ahead — both sell out, and mornings beat the crowds."
        ),

        // Oceania, South America, Middle East & Africa
        Destination(
            id: "sydney",
            title: "Sydney Shores", city: "Sydney", country: "Australia",
            tags: ["6 days", "Coastal"], planner: "Charlotte Nguyen", price: "$2.9k",
            dailyBudget: "~$485/day", stops: 11, isFeatured: true, symbol: "sailboat.fill",
            colors: [.blue, .cyan],
            places: [
                TravelPlanItem(name: "Opera House + Circular Quay", detail: "Harbour icons, Botanic Garden loop, and Mrs Macquarie's Chair views.", cost: "Low"),
                TravelPlanItem(name: "Bondi to Coogee walk", detail: "Clifftop coastal path linking beaches, pools, and lookout points.", cost: "Free"),
                TravelPlanItem(name: "Manly ferry", detail: "The classic harbour crossing; beach afternoon on the other side.", cost: "Low"),
                TravelPlanItem(name: "The Rocks", detail: "Weekend markets, colonial lanes, and harbour-view pubs under the bridge.", cost: "Low-mid"),
                TravelPlanItem(name: "Blue Mountains day trip", detail: "Three Sisters lookout, Scenic World, and eucalyptus valley trails.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Sydney Fish Market", detail: "Pick-and-grill seafood by the wharf.", cost: "$$"),
                TravelPlanItem(name: "Chat Thai", detail: "Late-night Thai institution in Haymarket.", cost: "$-$$"),
                TravelPlanItem(name: "Bourke Street Bakery", detail: "Sausage rolls and ginger brûlée tarts.", cost: "$"),
                TravelPlanItem(name: "The Grounds of Alexandria", detail: "Garden-set brunch worth the ride south.", cost: "$$")
            ],
            plannerNote: "Ferries double as sightseeing — use an Opal card and ride them instead of booking harbour cruises."
        ),
        Destination(
            id: "rio-de-janeiro",
            title: "Rio Rhythms", city: "Rio de Janeiro", country: "Brazil",
            tags: ["5 days", "Beach"], planner: "Lucas Almeida", price: "$1.8k",
            dailyBudget: "~$360/day", stops: 10, isFeatured: true, symbol: "figure.surfing",
            colors: [.green, .yellow],
            places: [
                TravelPlanItem(name: "Christ the Redeemer", detail: "Cog train up Corcovado early, before the clouds and crowds roll in.", cost: "Mid"),
                TravelPlanItem(name: "Sugarloaf cable car", detail: "Two-stage ride timed for sunset over Guanabara Bay.", cost: "Mid"),
                TravelPlanItem(name: "Copacabana + Ipanema", detail: "Beach mornings, calçadão strolls, and coconut-water breaks.", cost: "Low"),
                TravelPlanItem(name: "Santa Teresa + Selarón Steps", detail: "Hilltop art district and the famous tiled staircase.", cost: "Low"),
                TravelPlanItem(name: "Tijuca Forest", detail: "Waterfalls and viewpoints in the world's largest urban rainforest.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Confeitaria Colombo", detail: "Belle-époque café for pastéis de nata and people-watching.", cost: "$$"),
                TravelPlanItem(name: "Cervantes", detail: "Late-night roast pork and pineapple sandwiches in Copacabana.", cost: "$"),
                TravelPlanItem(name: "Churrascaria Palace", detail: "Classic all-you-can-eat rodízio near the beach.", cost: "$$$"),
                TravelPlanItem(name: "Beach kiosks", detail: "Grilled cheese skewers, açaí bowls, and caipirinhas on the sand.", cost: "$")
            ],
            plannerNote: "Do the big viewpoints on the clearest day of the forecast and keep beach days flexible."
        ),
        Destination(
            id: "istanbul",
            title: "Istanbul Crossroads", city: "Istanbul", country: "Turkey",
            tags: ["5 days", "Culture"], planner: "Elif Demir", price: "$1.6k",
            dailyBudget: "~$320/day", stops: 12, isFeatured: false, symbol: "moon.stars.fill",
            colors: [.teal, .indigo],
            places: [
                TravelPlanItem(name: "Hagia Sophia + Blue Mosque", detail: "The two Sultanahmet giants face each other across a park.", cost: "Low-mid"),
                TravelPlanItem(name: "Topkapi Palace", detail: "Ottoman courtyards, the Harem, and Bosphorus terrace views.", cost: "Mid"),
                TravelPlanItem(name: "Grand Bazaar + Spice Bazaar", detail: "4,000 shops of carpets, lamps, lokum, and haggling practice.", cost: "Low"),
                TravelPlanItem(name: "Bosphorus ferry", detail: "Commuter boat between continents for the price of a coffee.", cost: "Low"),
                TravelPlanItem(name: "Galata + Karaköy", detail: "Tower views, steep café lanes, and the city's best baklava.", cost: "Low-mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Çiya Sofrası", detail: "Anatolian home cooking worth the ferry to Kadıköy.", cost: "$$"),
                TravelPlanItem(name: "Karaköy Güllüoğlu", detail: "The baklava benchmark since 1949.", cost: "$"),
                TravelPlanItem(name: "Sultanahmet Köftecisi", detail: "Grilled meatballs steps from the old-city sights.", cost: "$"),
                TravelPlanItem(name: "Balık ekmek boats", detail: "Grilled fish sandwiches off the Eminönü waterfront.", cost: "$")
            ],
            plannerNote: "Stay in Sultanahmet or Karaköy, buy an Istanbulkart, and let the ferries be your sightseeing cruises."
        ),
        Destination(
            id: "amsterdam",
            title: "Amsterdam Canals", city: "Amsterdam", country: "Netherlands",
            tags: ["3 days", "Design"], planner: "Daan de Vries", price: "$2.1k",
            dailyBudget: "~$700/day", stops: 9, isFeatured: false, symbol: "bicycle",
            colors: [.orange, .blue],
            places: [
                TravelPlanItem(name: "Canal Ring walk", detail: "Golden-age gables along Herengracht and Prinsengracht at dusk.", cost: "Free"),
                TravelPlanItem(name: "Rijksmuseum", detail: "Rembrandt's Night Watch and the Vermeer room; book a slot.", cost: "Mid"),
                TravelPlanItem(name: "Van Gogh Museum", detail: "Timed-entry only — reserve days ahead.", cost: "Mid"),
                TravelPlanItem(name: "Jordaan", detail: "Hofjes courtyards, brown cafés, and the Noordermarkt on Saturdays.", cost: "Low"),
                TravelPlanItem(name: "Vondelpark by bike", detail: "Rent a bike and loop the park like a local.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Foodhallen", detail: "Indoor food hall for bitterballen and worldwide small plates.", cost: "$$"),
                TravelPlanItem(name: "Winkel 43", detail: "The famous appeltaart with whipped cream.", cost: "$"),
                TravelPlanItem(name: "The Pancake Bakery", detail: "Dutch pancakes in a canal-house cellar.", cost: "$$"),
                TravelPlanItem(name: "Herring stands", detail: "Raw herring with onions — the true local snack.", cost: "$")
            ],
            plannerNote: "Book both big museums before you fly; everything else is best discovered on foot or by bike."
        ),
        Destination(
            id: "dubai",
            title: "Dubai Heights", city: "Dubai", country: "UAE",
            tags: ["4 days", "Modern"], planner: "Aisha Al Mansoori", price: "$2.6k",
            dailyBudget: "~$650/day", stops: 8, isFeatured: false, symbol: "building.fill",
            colors: [.yellow, .orange],
            places: [
                TravelPlanItem(name: "Burj Khalifa + Dubai Mall", detail: "At the Top at sunset, then the fountain show below.", cost: "Mid-high"),
                TravelPlanItem(name: "Old Dubai + abra ride", detail: "Al Fahidi lanes, gold and spice souks, one-dirham creek crossing.", cost: "Low"),
                TravelPlanItem(name: "Desert safari", detail: "Dune drive, camel stop, and barbecue camp at sundown.", cost: "Mid-high"),
                TravelPlanItem(name: "Dubai Marina walk", detail: "Skyscraper promenade with beach access at JBR.", cost: "Free"),
                TravelPlanItem(name: "Jumeirah Mosque", detail: "The one mosque open to non-Muslim visitors, via guided tour.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Ravi Restaurant", detail: "Legendary Pakistani canteen in Satwa.", cost: "$"),
                TravelPlanItem(name: "Al Ustad Special Kabab", detail: "Photo-covered Iranian grill running since 1978.", cost: "$"),
                TravelPlanItem(name: "Arabian Tea House", detail: "Emirati breakfast in an Al Fahidi courtyard.", cost: "$$"),
                TravelPlanItem(name: "Bu Qtair", detail: "Grilled fish shack by the Jumeirah fishing harbour.", cost: "$-$$")
            ],
            plannerNote: "Split days between old and new Dubai — the creek side costs almost nothing and balances the splurges."
        ),
        Destination(
            id: "cairo",
            title: "Cairo Wonders", city: "Cairo", country: "Egypt",
            tags: ["4 days", "History"], planner: "Omar Hassan", price: "$1.2k",
            dailyBudget: "~$300/day", stops: 9, isFeatured: false, symbol: "sun.dust.fill",
            colors: [.orange, .yellow],
            places: [
                TravelPlanItem(name: "Giza Pyramids + Sphinx", detail: "Arrive at opening, walk the plateau, and skip the camel hustle.", cost: "Mid"),
                TravelPlanItem(name: "Grand Egyptian Museum", detail: "Tutankhamun's treasures beside the plateau; give it half a day.", cost: "Mid"),
                TravelPlanItem(name: "Khan el-Khalili", detail: "Medieval bazaar lanes and mint tea at El Fishawy café.", cost: "Low"),
                TravelPlanItem(name: "Coptic Cairo", detail: "Hanging Church, early monasteries, and Roman fortress walls.", cost: "Low"),
                TravelPlanItem(name: "Nile felucca at sunset", detail: "An hour under sail as the city lights come on.", cost: "Low")
            ],
            restaurants: [
                TravelPlanItem(name: "Koshary Abou Tarek", detail: "The definitive plate of Egypt's national comfort food.", cost: "$"),
                TravelPlanItem(name: "Zooba", detail: "Modern takes on taameya and hawawshi.", cost: "$"),
                TravelPlanItem(name: "Abou El Sid", detail: "Classic Egyptian dishes in an old-Cairo dining room.", cost: "$$"),
                TravelPlanItem(name: "El Fishawy", detail: "Mint tea and shisha at a 250-year-old bazaar café.", cost: "$")
            ],
            plannerNote: "Hire a driver or use ride apps between sites, and put the pyramids first before the heat builds."
        ),
        Destination(
            id: "los-angeles",
            title: "Los Angeles Highlights", city: "Los Angeles", country: "USA",
            tags: ["5 days", "Urban"], planner: "Maya Chen", price: "$2.8k",
            dailyBudget: "~$560/day", stops: 11, isFeatured: true, symbol: "sun.max.fill",
            colors: [.orange, .pink],
            places: [
                TravelPlanItem(name: "Griffith Observatory", detail: "City views, space exhibits, and a sunset look toward the Hollywood Sign.", cost: "Low"),
                TravelPlanItem(name: "Getty Center", detail: "Architecture, gardens, major art collections, and wide Westside views.", cost: "Low"),
                TravelPlanItem(name: "Santa Monica + Venice", detail: "Start at the pier, follow the beach path, and finish near the Venice canals.", cost: "Low-mid"),
                TravelPlanItem(name: "Academy Museum + LACMA", detail: "A focused museum day around film, design, and modern art on Museum Row.", cost: "Mid"),
                TravelPlanItem(name: "Downtown Arts District", detail: "Murals, independent shops, Little Tokyo, and an evening around Broadway.", cost: "Low-mid"),
                TravelPlanItem(name: "Universal Studios Hollywood", detail: "A full theme-park day; reserve the first entry window you can use.", cost: "High")
            ],
            restaurants: [
                TravelPlanItem(name: "Grand Central Market", detail: "A flexible downtown lunch with tacos, noodles, sandwiches, and sweets.", cost: "$-$$"),
                TravelPlanItem(name: "Guelaguetza", detail: "Oaxacan mole, tlayudas, and a lively Koreatown dining room.", cost: "$$"),
                TravelPlanItem(name: "Holbox", detail: "Bright Mexican seafood near USC, especially ceviche and smoked fish tacos.", cost: "$$"),
                TravelPlanItem(name: "Howlin' Ray's", detail: "Nashville-style hot chicken with a heat level for every table.", cost: "$"),
                TravelPlanItem(name: "Porto's Bakery", detail: "Cuban pastries and savory potato balls for an inexpensive breakfast stop.", cost: "$")
            ],
            plannerNote: "Treat Los Angeles as several small cities: group each day by neighborhood and avoid crossing town at rush hour."
        ),
        Destination(
            id: "cancun",
            title: "Cancún Caribbean", city: "Cancún", country: "Mexico",
            tags: ["5 days", "Beach"], planner: "Valeria Cruz", price: "$2.3k",
            dailyBudget: "~$460/day", stops: 10, isFeatured: true, symbol: "beach.umbrella.fill",
            colors: [.cyan, .blue],
            places: [
                TravelPlanItem(name: "Isla Mujeres", detail: "Take the morning ferry for Playa Norte, snorkeling, and a slower island pace.", cost: "Mid"),
                TravelPlanItem(name: "MUSA Underwater Museum", detail: "Snorkel or dive above submerged sculptures in clear Caribbean water.", cost: "Mid-high"),
                TravelPlanItem(name: "Chichén Itzá", detail: "A long but rewarding day trip; pair the ruins with a nearby cenote swim.", cost: "Mid-high"),
                TravelPlanItem(name: "Hotel Zone beaches", detail: "Choose one easy beach day around Playa Delfines and the lagoon viewpoints.", cost: "Low"),
                TravelPlanItem(name: "Puerto Morelos", detail: "A quieter fishing town for reef snorkeling and an unhurried waterfront lunch.", cost: "Mid"),
                TravelPlanItem(name: "Cenote route", detail: "Pick one or two managed cenotes rather than rushing through a full circuit.", cost: "Mid")
            ],
            restaurants: [
                TravelPlanItem(name: "Parque de las Palapas", detail: "Evening food stalls for tacos, marquesitas, and casual local snacks.", cost: "$"),
                TravelPlanItem(name: "El Fish Fritanga", detail: "Lagoon-side seafood with ceviche, grilled fish, and relaxed outdoor tables.", cost: "$$"),
                TravelPlanItem(name: "La Habichuela", detail: "Long-running Cancún dining room for Yucatecan and Caribbean flavors.", cost: "$$$"),
                TravelPlanItem(name: "Marakame Café", detail: "Garden breakfast and an easy reset away from the resort strip.", cost: "$$")
            ],
            plannerNote: "Balance two beach days with one island day and one inland outing; keep the final day flexible for weather."
        ),
        Destination(
            id: "santorini",
            title: "Santorini Caldera", city: "Santorini", country: "Greece",
            tags: ["4 days", "Romantic"], planner: "Eleni Markou", price: "$2.4k",
            dailyBudget: "~$600/day", stops: 9, isFeatured: true, symbol: "water.waves",
            colors: [.blue, .cyan],
            places: [
                TravelPlanItem(name: "Fira to Oia hike", detail: "A caldera-edge walk through Firostefani and Imerovigli; start before the heat.", cost: "Free"),
                TravelPlanItem(name: "Oia lanes", detail: "Explore early, pause for gallery courtyards, and choose a quieter sunset terrace.", cost: "Low-mid"),
                TravelPlanItem(name: "Akrotiri", detail: "Walk the sheltered Bronze Age settlement, then continue to the south-coast beaches.", cost: "Mid"),
                TravelPlanItem(name: "Caldera sailing", detail: "Half-day boat route around the volcanic islets and hot-spring coves.", cost: "High"),
                TravelPlanItem(name: "Pyrgos + wine country", detail: "Hilltop alleys followed by a tasting focused on the island's volcanic vineyards.", cost: "Mid-high")
            ],
            restaurants: [
                TravelPlanItem(name: "Metaxi Mas", detail: "Cretan and Cycladic dishes in Exo Gonia; reserve an outdoor table.", cost: "$$"),
                TravelPlanItem(name: "To Psaraki", detail: "Straightforward seafood above Vlychada marina.", cost: "$$-$$$"),
                TravelPlanItem(name: "Lucky's Souvlakis", detail: "Quick, affordable gyros in central Fira.", cost: "$"),
                TravelPlanItem(name: "Aktaion", detail: "A compact Firostefani taverna with island classics and caldera atmosphere.", cost: "$$")
            ],
            plannerNote: "Stay near Fira for buses or Imerovigli for quiet views, and avoid scheduling every sunset in crowded Oia."
        ),
        Destination(
            id: "marrakech",
            title: "Marrakech Medina", city: "Marrakech", country: "Morocco",
            tags: ["4 days", "Markets"], planner: "Salma Idrissi", price: "$1.4k",
            dailyBudget: "~$350/day", stops: 10, isFeatured: true, symbol: "sun.dust.fill",
            colors: [.orange, .red],
            places: [
                TravelPlanItem(name: "Jemaa el-Fna + souks", detail: "Walk the market lanes by day, then return as the square fills with evening food stalls.", cost: "Low"),
                TravelPlanItem(name: "Bahia Palace", detail: "Zellige courtyards, carved cedar, and gardens best seen near opening.", cost: "Low-mid"),
                TravelPlanItem(name: "Jardin Majorelle", detail: "A vivid garden and design stop; reserve a timed entry before arrival.", cost: "Mid"),
                TravelPlanItem(name: "Ben Youssef Madrasa", detail: "A restored historic school with intricate geometric interiors.", cost: "Low-mid"),
                TravelPlanItem(name: "Koutoubia + Menara Gardens", detail: "Pair the landmark minaret with a slower late-afternoon garden walk.", cost: "Low"),
                TravelPlanItem(name: "Atlas Mountains day trip", detail: "Choose a small-group route with village time instead of a rushed multi-stop circuit.", cost: "Mid-high")
            ],
            restaurants: [
                TravelPlanItem(name: "Nomad", detail: "Modern Moroccan plates on a medina rooftop; sunset reservations go quickly.", cost: "$$"),
                TravelPlanItem(name: "Amal Women's Training Center", detail: "Warm home-style lunch that supports hospitality training.", cost: "$"),
                TravelPlanItem(name: "Chez Lamine", detail: "Slow-roasted tangia and mechoui close to the market action.", cost: "$-$$"),
                TravelPlanItem(name: "Le Jardin", detail: "A leafy courtyard break for Moroccan dishes and mint tea.", cost: "$$")
            ],
            plannerNote: "Use a licensed guide for the first medina walk, keep cash for small purchases, and build in a quiet midday reset."
        ),
    ]
}

extension Destination {
    /// A deliberate discovery order: globally recognizable first-trip cities lead,
    /// while every remaining guide keeps a stable position after the ranked set.
    private static let popularityOrder = [
        "paris", "tokyo", "new-york", "london", "rome", "barcelona",
        "los-angeles", "bangkok", "dubai", "bali", "singapore", "cancun",
        "kyoto", "seoul", "amsterdam", "santorini", "sydney", "istanbul",
        "mexico-city", "marrakech", "osaka", "honolulu", "san-francisco",
        "lisbon", "taipei", "vancouver", "rio-de-janeiro", "las-vegas", "cairo"
    ]

    var popularityRank: Int {
        Self.popularityOrder.firstIndex(of: id) ?? Self.popularityOrder.count
    }

    static var popularFirst: [Destination] {
        all.enumerated()
            .sorted {
                let lhs = $0.element.popularityRank
                let rhs = $1.element.popularityRank
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            .map(\.element)
    }
}

extension Destination {
    /// The short overview paragraph shown on the detail page.
    var blurb: String {
        switch id {
        case "tokyo": "Neon crossings, temple mornings, and the world's densest food scene — Tokyo rewards wandering between neighborhoods that each feel like their own city."
        case "kyoto": "Kyoto trades skyline for shrine paths, bamboo groves, and quiet lanes where old Japan is still the everyday backdrop."
        case "seoul": "Palaces by day and street food by night — Seoul layers hanok alleys, mountain viewpoints, and 24-hour markets into one compact grid."
        case "bangkok": "Gilded temples, river boats, and markets that never quite close: Bangkok is chaotic, cheap, and endlessly delicious."
        case "singapore": "A garden city of supertrees, hawker centres, and shophouse neighborhoods, all threaded together by spotless transit."
        case "bali": "Rice terraces, cliff temples, and slow beach afternoons — Bali balances jungle mornings in Ubud with coastal sunsets in Uluwatu."
        case "new-york": "Skyline walks, world-class museums, and a different cuisine on every block — New York packs more per day than any other city."
        case "san-francisco": "Fog over the Golden Gate, murals in the Mission, and coastal trails at the city's edge — San Francisco is best explored one neighborhood at a time."
        case "vancouver": "Mountains, seawall, and rainforest inside city limits — Vancouver mixes outdoor days with a serious food scene."
        case "las-vegas": "Beyond the Strip's lights are neon museums, downtown Fremont, and red-rock desert an easy half-day away."
        case "mexico-city": "Aztec ruins, world-class museums, leafy plazas, and tacos on every corner — CDMX runs deep on culture and flavor."
        case "osaka": "Neon canals, castle grounds, and Japan's best street food — Osaka is Tokyo's louder, hungrier sibling."
        case "taipei": "Night markets, mountain trails inside the city, and hot springs a metro ride away — Taipei packs a lot into a small, friendly grid."
        case "paris": "Café terraces, riverside museums, and a skyline stitched together by the Eiffel Tower — Paris makes every walk feel like the main event."
        case "rome": "Ancient ruins share sidewalks with espresso bars and trattorie — Rome layers two thousand years of history into a very walkable center."
        case "barcelona": "Gaudí's spires, Gothic lanes, and a city beach at the end of the metro — Barcelona mixes architecture, tapas, and sea air."
        case "london": "Royal parks, free world-class museums, and markets from Borough to Portobello — London rewards long walks and theatre nights."
        case "lisbon": "Tiled facades, viewpoint terraces, and custard tarts still warm from the oven — Lisbon climbs its seven hills at an easy pace."
        case "honolulu": "Waikiki surf mornings, volcanic crater hikes, and plate-lunch afternoons — Honolulu blends big-city ease with island pace."
        case "sydney": "Harbour ferries, clifftop beach walks, and an opera house that earns the postcards — Sydney lives outdoors."
        case "rio-de-janeiro": "Beaches framed by granite peaks, samba spilling out of botecos, and a rainforest inside the city — Rio moves to its own rhythm."
        case "istanbul": "Minarets over the Bosphorus, bazaars that have run for five centuries, and ferries that commute between continents — Istanbul is layered like nowhere else."
        case "amsterdam": "Gabled canals, world-class art in walkable doses, and bikes outnumbering people — Amsterdam is a compact golden-age city built for wandering."
        case "dubai": "Record-breaking towers on one side of the creek and century-old souks on the other — Dubai does spectacle and tradition in the same day."
        case "cairo": "The pyramids at the edge of the city, treasure-filled museums, and bazaar lanes older than most countries — Cairo is history at full volume."
        case "los-angeles": "Ocean sunsets, hillside views, film history, and food from every corner of the world — Los Angeles works best as a series of neighborhood-sized adventures."
        case "cancun": "Turquoise water is the headline, but island ferries, cenotes, Maya history, and lively local food give Cancún far more range than a resort-only stay."
        case "santorini": "Whitewashed villages trace a volcanic caldera above the Aegean, with cliff walks, ancient ruins, and vineyard afternoons beyond the famous sunsets."
        case "marrakech": "Ochre lanes, tiled palaces, garden courtyards, and a market square that transforms after dark make Marrakech an immersive first stop in Morocco."
        default: "A curated plan with hand-picked places to visit and eat."
        }
    }

    struct PracticalGuide {
        let base: String
        let transport: String
        let booking: String
    }

    /// Practical trip-level context for every curated destination. These are
    /// deliberately specific enough to shape an itinerary, but avoid brittle
    /// claims such as exact hours, fares, or availability that can change.
    var practicalGuide: PracticalGuide {
        switch id {
        case "tokyo": .init(base: "Ueno, Ginza, or Shinjuku for easy rail access.", transport: "Use an IC transit card; plan days by neighborhood.", booking: "Timed attractions and popular dinner slots.")
        case "kyoto": .init(base: "Gion, Kawaramachi, or Kyoto Station for a compact base.", transport: "Buses are useful, but group each day by district.", booking: "Temple-area meals and any seasonal evening visits.")
        case "seoul": .init(base: "Jongno for palaces, Myeongdong for transit, Hongdae for nights.", transport: "Metro first; use a taxi for late, cross-city hops.", booking: "Palace tours and a few restaurant backups.")
        case "bangkok": .init(base: "Riverside for temples or Sukhumvit for rail connections.", transport: "Pair river boats with BTS/MRT rather than road traffic.", booking: "One reliable airport transfer and a cooking class, if wanted.")
        case "singapore": .init(base: "City Hall, Bugis, or Tanjong Pagar keeps days central.", transport: "MRT handles nearly every sightseeing cluster.", booking: "Gardens conservatories and any Sentosa activities.")
        case "bali": .init(base: "Split Ubud and the coast instead of commuting across the island.", transport: "Arrange a driver for full-day temple or beach circuits.", booking: "Fast boats, airport transfers, and sunset venues.")
        case "osaka": .init(base: "Namba or Umeda puts food districts and rail lines close.", transport: "Walk each district, then use the metro between clusters.", booking: "One high-demand dinner; leave the rest flexible for snacks.")
        case "taipei": .init(base: "Zhongshan, Ximending, or Da'an for an easy MRT base.", transport: "Pick up a transit card and use the MRT for most days.", booking: "Taipei 101 and any hot-spring private rooms.")
        case "paris": .init(base: "Stay near a Metro line rather than chasing one landmark.", transport: "Cluster by arrondissement and walk between nearby stops.", booking: "Museum entries and one special dinner.")
        case "rome": .init(base: "Centro Storico or Monti makes early starts realistic.", transport: "Walk the historic core; reserve taxis for longer jumps.", booking: "Vatican, Colosseum, and any guided archaeology.")
        case "barcelona": .init(base: "Eixample or El Born balances sightseeing and evening dining.", transport: "Metro for longer hops; the center rewards walking.", booking: "Gaudí sites and a table for a late tapas dinner.")
        case "london": .init(base: "South Bank, Covent Garden, or Bloomsbury are well connected.", transport: "Tap in and out on public transit; group by zone.", booking: "Theatre, Tower of London, and popular restaurants.")
        case "lisbon": .init(base: "Baixa, Chiado, or Príncipe Real reduce hill-heavy returns.", transport: "Use trams and funiculars strategically; keep good walking shoes.", booking: "Sintra transport or a small-group day trip.")
        case "new-york": .init(base: "Midtown, Flatiron, or the Lower East Side suit first visits.", transport: "Subway for distance, walking for neighborhood exploration.", booking: "Observation decks, Broadway, and weekend brunch.")
        case "san-francisco": .init(base: "Union Square, North Beach, or Hayes Valley are central bases.", transport: "Use Muni and rideshares for hills; group by neighborhood.", booking: "Alcatraz and any Golden Gate bike rental.")
        case "vancouver": .init(base: "Downtown or Yaletown keeps the seawall and transit nearby.", transport: "Walk the core; use transit or car share for mountains.", booking: "Seasonal mountain activities and a flexible weather day.")
        case "las-vegas": .init(base: "Choose the Strip for convenience or Arts District for a quieter base.", transport: "Walk short sections; rideshare between distant resorts.", booking: "One show, a restaurant, and any desert excursion.")
        case "mexico-city": .init(base: "Roma Norte or Condesa are walkable, central starting points.", transport: "Metro and rideshare work best when you cluster neighborhoods.", booking: "Teotihuacan transport and a museum for popular weekends.")
        case "honolulu": .init(base: "Waikiki is practical for a car-free first stay.", transport: "Use rideshare or a rental for east and north shore days.", booking: "Diamond Head and Hanauma Bay before building the rest around them.")
        case "sydney": .init(base: "CBD, Surry Hills, or Circular Quay make ferry days easy.", transport: "Use ferries as transport and sightseeing in one.", booking: "Harbour activities, coastal tours, and a Blue Mountains day.")
        case "rio-de-janeiro": .init(base: "Ipanema or Copacabana are practical, beach-forward bases.", transport: "Use licensed rideshares between neighborhoods, especially after dark.", booking: "Major viewpoints for the clearest forecast day.")
        case "istanbul": .init(base: "Sultanahmet for sights or Karaköy for a livelier, central stay.", transport: "Load an Istanbulkart and use ferries to connect districts.", booking: "Palace tickets and a Bosphorus experience if desired.")
        case "amsterdam": .init(base: "Jordaan, De Pijp, or the Canal Ring keeps most stops walkable.", transport: "Walk, bike carefully, or use trams for longer trips.", booking: "Rijksmuseum and Van Gogh Museum before arrival.")
        case "dubai": .init(base: "Downtown for landmarks or Al Seef for old-Dubai character.", transport: "Metro covers the spine; taxis fill the gaps efficiently.", booking: "Burj Khalifa, a desert operator, and any beach club.")
        case "cairo": .init(base: "Zamalek or Downtown work well for a first-time base.", transport: "Use a vetted driver or rideshare between major sights.", booking: "A Giza guide or transport, plus museum entry if needed.")
        case "los-angeles": .init(base: "West Hollywood for central access, Santa Monica for the coast, or Downtown for transit.", transport: "Group days by neighborhood; use Metro where direct and rideshare for the gaps.", booking: "Studio tours, theme parks, and any timed museum entry.")
        case "cancun": .init(base: "Hotel Zone for a beach-first stay or downtown for local food and lower prices.", transport: "Use buses along the resort corridor and booked transfers for longer outings.", booking: "Ferries, reef trips, and a reputable inland day tour.")
        case "santorini": .init(base: "Fira for transport, Imerovigli for quieter caldera views, or Kamari for the beach.", transport: "Use buses for main villages; reserve a car only for a focused island loop.", booking: "Sailing, vineyard tastings, and any sunset dinner that matters.")
        case "marrakech": .init(base: "A riad inside the medina for atmosphere or Hivernage for easier vehicle access.", transport: "Walk the medina, then use licensed taxis or arranged drivers beyond it.", booking: "Jardin Majorelle, a first-day guide, and a vetted Atlas excursion.")
        default: .init(base: "Choose a central, well-connected neighborhood.", transport: "Group stops by area and rely on local transit.", booking: "Reserve the one experience you would be disappointed to miss.")
        }
    }

    /// City-center coordinate, used to bias the Map tab's POI search and as the
    /// fallback pin location when a specific place can't be resolved.
    var coordinate: CLLocationCoordinate2D {
        switch id {
        case "tokyo": CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        case "kyoto": CLLocationCoordinate2D(latitude: 35.0116, longitude: 135.7681)
        case "seoul": CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        case "bangkok": CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018)
        case "singapore": CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
        case "bali": CLLocationCoordinate2D(latitude: -8.4095, longitude: 115.1889)
        case "new-york": CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        case "san-francisco": CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        case "vancouver": CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)
        case "las-vegas": CLLocationCoordinate2D(latitude: 36.1699, longitude: -115.1398)
        case "mexico-city": CLLocationCoordinate2D(latitude: 19.4326, longitude: -99.1332)
        case "osaka": CLLocationCoordinate2D(latitude: 34.6937, longitude: 135.5023)
        case "taipei": CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        case "paris": CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        case "rome": CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964)
        case "barcelona": CLLocationCoordinate2D(latitude: 41.3874, longitude: 2.1686)
        case "london": CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        case "lisbon": CLLocationCoordinate2D(latitude: 38.7223, longitude: -9.1393)
        case "honolulu": CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583)
        case "sydney": CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
        case "rio-de-janeiro": CLLocationCoordinate2D(latitude: -22.9068, longitude: -43.1729)
        case "istanbul": CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784)
        case "amsterdam": CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.9041)
        case "dubai": CLLocationCoordinate2D(latitude: 25.2048, longitude: 55.2708)
        case "cairo": CLLocationCoordinate2D(latitude: 30.0444, longitude: 31.2357)
        case "los-angeles": CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        case "cancun": CLLocationCoordinate2D(latitude: 21.1619, longitude: -86.8515)
        case "santorini": CLLocationCoordinate2D(latitude: 36.3932, longitude: 25.4615)
        case "marrakech": CLLocationCoordinate2D(latitude: 31.6295, longitude: -7.9811)
        default: CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
    }
}

extension Destination {
    /// Asset-catalog name of the bundled photo for this curated trip.
    var imageName: String { "explore-\(id)" }
}

// MARK: Filterable facets (derived, so curated entries stay single-source)

extension Destination {
    /// Trip length in days, parsed from the first tag ("5 days" → 5).
    var days: Int {
        tags.first.flatMap { Int($0.split(separator: " ").first ?? "") } ?? 0
    }

    /// Numeric total budget, parsed from `price` ("$2.5k" → 2500).
    var budgetValue: Double {
        let trimmed = price.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        if trimmed.hasSuffix("k"), let value = Double(trimmed.dropLast()) { return value * 1000 }
        return Double(trimmed) ?? 0
    }

    /// Continent bucket for the filter, keyed off the country.
    var continent: String {
        switch country {
        case "Japan", "South Korea", "Thailand", "Singapore", "Indonesia", "Taiwan": "Asia"
        case "France", "Italy", "Spain", "UK", "Portugal", "Netherlands", "Turkey", "Greece": "Europe"
        case "USA", "Canada", "Mexico": "North America"
        case "Brazil": "South America"
        case "UAE", "Egypt", "Morocco": "Middle East & Africa"
        case "Australia": "Oceania"
        default: "Other"
        }
    }

    /// A ready-to-edit trip seeded from this curated plan, for users who'd rather
    /// start from a template than a blank itinerary: the curated budget becomes the
    /// itinerary budget, and the curated places/restaurants are spread round-robin
    /// across the trip's days (each day tends to get a sight and a meal). Everything
    /// is a normal `ItineraryStop` afterwards — rename, retime, or delete freely.
    func starterTrip(creator me: Person) -> Trip {
        let dayCount = min(max(days, 1), 30)
        var itineraryDays = (0..<dayCount).map { _ in ItineraryDay() }
        for (index, place) in places.enumerated() {
            itineraryDays[index % dayCount].stops.append(
                ItineraryStop(name: place.name, kind: .location, notes: place.detail)
            )
        }
        for (index, restaurant) in restaurants.enumerated() {
            itineraryDays[index % dayCount].stops.append(
                ItineraryStop(name: restaurant.name, kind: .restaurant, notes: restaurant.detail)
            )
        }
        let budget = SplitEngine.roundToTwo(budgetValue)
        return Trip(
            name: title,
            currencyCode: "USD",
            creatorID: me.id,
            members: [me],
            budgets: [me.id: budget],
            location: "\(city), \(country)",
            itinerary: Itinerary(totalBudget: budget, days: itineraryDays)
        )
    }

    /// Continents in display order, limited to ones that actually have trips.
    static var continents: [String] {
        let order = ["Asia", "Europe", "North America", "South America", "Middle East & Africa", "Oceania", "Other"]
        let present = Set(all.map(\.continent))
        return order.filter(present.contains)
    }
}

/// The destination's bundled photo, cropped to fill whatever frame it's given.
/// Falls back to the old gradient + symbol placeholder if a (future) destination
/// id has no matching asset, so new entries degrade gracefully instead of breaking.
