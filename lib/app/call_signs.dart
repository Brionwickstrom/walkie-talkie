/// Default names for phones whose owner never typed one: a stable, funny /
/// classic call sign picked from the phone's permanent id, so every other
/// phone shows the same name every time.
///
/// Mix of CB trucker handles, aviation call signs, NATO-alphabet combos and
/// plain silly ones. All clean, none are a character's name verbatim.
const List<String> callSigns = [
  // CB radio / trucker
  'Rubber Duck', 'Bandit', 'Smokey\'s Cousin', 'Big Wheel', 'Night Owl',
  'Road Runner Jr.', 'Gravel Gertie', 'Diesel Dan', 'Hammer Down',
  'Ten-Four Toaster', 'Breaker Breaker', 'Mud Flap', 'Chicken Coop',
  'Pickle Hauler', 'Convoy Cowboy', 'Lonesome Trucker', 'Hot Coffee',
  'Bear Bait', 'Back Door', 'Good Buddy', 'Cattle Guard',
  'Flip-Flop', 'Wiggle Wagon', 'Big Ol\' Rig',
  // Aviation / military style
  'Maverick', 'Iceberg', 'Goose Egg', 'Viper', 'Jester', 'Hollywood',
  'Thunderbolt', 'Night Hawk', 'Sky Pilot', 'Wingnut', 'Afterburner',
  'Red Baron Jr.', 'Ghost Pepper', 'Tailspin', 'Mayday Mike', 'Barnstormer',
  'Top Dollar', 'Eagle Eye', 'Sidewinder', 'Crosswind',
  // NATO alphabet combos
  'Tango Foxtrot', 'Echo Echo', 'Whiskey Tango', 'Bravo Zulu',
  'Charlie Oscar', 'Delta Kilo', 'Sierra Hotel', 'Lima Bean',
  'Oscar Mike', 'Papa Bear', 'Kilo Tango', 'Victor Victor',
  'Yankee Doodle', 'Romeo Juliet', 'Hotel Quebec', 'November Noodle',
  'India Ink', 'Golf Sierra', 'Uniform Pants', 'X-Ray Specs',
  // Silly
  'Captain Crunchwrap', 'Sir Beeps-a-Lot', 'Pancake Overlord',
  'Admiral Nap Time', 'Duke of Static', 'Baron von Waffle',
  'Lord of the Fries', 'Professor Mumbles', 'Count Snackula',
  'Major Malfunction', 'Sergeant Sprinkles', 'Commander Cheddar',
  'General Nuisance', 'Queen of Crumbs', 'Agent Cuddles',
  'Doctor Wobbles', 'Taco Tuesday', 'Captain Clipboard',
  'Mister Roger Roger', 'Over and Owl', 'Squawk Box', 'Hamster Wheel',
  'Noodle Ninja', 'Biscuit Bandit', 'Turbo Turtle', 'Burrito Bravo',
  'Grumpy Goose', 'Waffle Commander', 'Potato Pilot', 'Disco Llama',
  'Soggy Cereal', 'Moose on the Loose', 'Meatball Express',
  'Sir Talks-a-Lot', 'Lady Loud Speaker', 'Pickle Rickshaw',
  'Captain Kazoo', 'Baron Bubblewrap', 'Gnome Alone', 'Banana Phone',
  'Quack Commander', 'Space Cadet', 'Wombat Whisperer',
  'Mothership', 'Loud and Clear', 'Static Cling',
  'Unit Unicorn', 'Popcorn Patrol', 'Yeti Spaghetti', 'Cosmic Chicken',
  'Cheese Wheel', 'Loud Mouth Larry', 'Whisper Wizard', 'Radio Raccoon',
];

/// Stable call sign for [nodeId]. [salt] is bumped by the "reroll" button,
/// salt 0 is the phone's original call sign.
String callSignFor(int nodeId, {int salt = 0}) {
  // splitmix-style mixing so neighbouring ids don't get neighbouring names.
  var x = (nodeId + salt * 0x9E3779B1) & 0xFFFFFFFF;
  x = ((x ^ (x >> 16)) * 0x85EBCA6B) & 0xFFFFFFFF;
  x = ((x ^ (x >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF;
  x = x ^ (x >> 16);
  return callSigns[x % callSigns.length];
}
