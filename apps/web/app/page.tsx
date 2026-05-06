import { prisma } from "database";

export const dynamic = "force-dynamic";

export default async function IndexPage() {
  const users = await prisma.user.findMany();
  return (
    <div>
      <h1>
        output of <i>prisma.user.findMany()</i>
      </h1>
      <pre>{JSON.stringify(users, null, 2)}</pre>
    </div>
  );
}
