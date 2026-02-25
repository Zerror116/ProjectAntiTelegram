class User {
  final String id;
  final String email;
  final String? name;
  final String role;

  User({required this.id, required this.email, this.name, required this.role});

  factory User.fromMap(Map<String, dynamic> m) => User(
    id: m['id'].toString(),
    email: m['email'].toString(),
    name: m['name']?.toString(),
    role: m['role']?.toString() ?? 'client',
  );
}
